#!/usr/bin/env bash
#
# mayhem/build.sh — build upstream's own cargo-fuzz binary (fuzz/fuzz_targets/run.rs) as a
# sanitized libFuzzer binary, build the additive mayhem/kat/ KAT-probe crate (a clean, dynamically
# linked oracle binary), and precompile the crate's own `cargo test` suite for mayhem/test.sh to
# run.
#
# SHAPE: upstream's fuzz/ crate ships ONE binary ("run") that internally multiplexes 11
# sub-fuzzers (fuzz/src/*.rs) selected at RUNTIME via the FUZZER env var (see CONTRIBUTING.md:
# "Due to limitations on OSS-Fuzz all fuzzers are combined into a single binary at this time.").
# We build that one binary once and ship it under 11 Mayhemfile_* targets, each pinning a
# different FUZZER env value (mayhem/<target>/Mayhemfile_<target>).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE. This first
# (online) build populates the cargo registry under $CARGO_HOME (pinned, $HOME-independent —
# see the Dockerfile). Do NOT pass --offline here; the rlenv runtime exports
# CARGO_NET_OFFLINE=true for the re-run.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

RUST_STABLE_TOOLCHAIN="${RUST_STABLE_TOOLCHAIN:-1.88.0}"

# REBUILD BUDGET (#1183). rlenv re-runs this script to grade a patch inside a fixed 450 s build
# window, offline, keeping target/ (Cargo repos are exempt from its pre-build `git clean`). A
# wasmparser fix rebuilds wasmparser and every workspace crate above it (wasm-encoder, wast, wat,
# wasmprinter, wit-parser, wit-component, wasm-mutate, wasm-smith, the fuzz crate) three times over:
# ASan fuzz binary, KAT probe, test suite. With the old serial layout that was 360-460 s at --cpus=4,
# at or over the window. What is done here, all from this script so no upstream file changes:
#  - the KAT probe and the test-suite precompile run CONCURRENTLY with the fuzz build (see below).
#    The fuzz build is bound by its crate chain (wasmparser -> wit-parser -> wasm-smith -> fuzz
#    crate), not by CPU: measured at about 2.2 busy cores of 4. The oracle builds use other profile
#    dirs (target/debug, mayhem/kat/target) and the stable toolchain, so they fill the idle cores
#    with the very same commands and outputs as when they ran after it.
#  - dev/test profile builds (the KAT probe and the test suite; debug-assertions and overflow checks
#    unchanged) carry line-tables-only debuginfo instead of full: same code, same panics and
#    backtrace lines, much less to emit and link. mayhem/test.sh exports the same value so it RUNS
#    the test binaries built here instead of recompiling them.
#  - the test suite links through lld (the base image's /usr/bin/ld.lld) instead of GNU ld: the
#    dozens of test executables relinked after a patch are pure link time, and the linker changes no
#    generated code. Only the linker argument differs from the old empty RUSTFLAGS; mayhem/test.sh
#    passes the identical TEST_RUSTFLAGS so it runs these binaries rather than rebuilding them.
export CARGO_PROFILE_DEV_DEBUG=line-tables-only
TEST_RUSTFLAGS="-Clink-arg=-fuse-ld=lld"

cd "$SRC"

# `fuzz/` is a member of the ROOT workspace ([workspace] members includes 'fuzz' in the root
# Cargo.toml) — so `cargo fuzz build` writes its output under the WORKSPACE ROOT
# target/<triple>/release/<bin>, NOT fuzz/target/... (confirmed empirically below via -x check).
FUZZ_DIR="fuzz"
TRIPLE="x86_64-unknown-linux-gnu"
BIN="run"

# ASan on by default; an explicitly EMPTY $SANITIZER_FLAGS disables it (build contract parity —
# $SANITIZER_FLAGS itself is a set of clang flags rustc can't consume directly, so translate its
# on/off intent instead of passing it through verbatim).
RUST_SAN="-Zsanitizer=address"
[ -z "${SANITIZER_FLAGS+x}" ] || [ -n "${SANITIZER_FLAGS}" ] || RUST_SAN=""
# DWARF <= 3 debug info for triage (SPEC §6.2 item 10) — threaded via RUST_DEBUG_FLAGS.
RUST_DEBUG_FLAGS="${RUST_DEBUG_FLAGS:--Cdebuginfo=1 -Zdwarf-version=3}"
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing $RUST_SAN $RUST_DEBUG_FLAGS -Cforce-frame-pointers"
# libfuzzer-sys's build.rs, by default, compiles libFuzzer's own C++ sources from source via the
# `cc` crate at build time — that build ignores CFLAGS/CXXFLAGS (cc::Build's own flags win) and
# links in DWARF-5 CUs from the base image's clang, which -Zdwarf-version=3 (a rustc-only flag)
# never touches. Point it at the base's prebuilt libFuzzer runtime instead (the same one the C/C++
# side gets via $LIB_FUZZING_ENGINE) — it ships with NO debug info at all, so it contributes zero
# DWARF-5 CUs, and libfuzzer-sys skips its own from-source compile entirely.
export CUSTOM_LIBFUZZER_PATH=/usr/lib/llvm-19/lib/clang/19/lib/linux/libclang_rt.fuzzer-x86_64.a

# rustc's prebuilt sanitizer runtimes (compiler-rt) ship DWARF-5 CUs — strip their debug info
# BEFORE linking, not after: the linker COPIES the relevant debug sections into the final binary
# at link time, so stripping the source .a afterward does nothing for a binary already linked
# against it. Idempotent: stripping an already-stripped archive is a no-op.
find "$RUSTUP_HOME"/toolchains/*/lib/rustlib/"$TRIPLE"/lib \
  -name 'librustc-*_rt.*.a' -exec objcopy --strip-debug {} \; 2>/dev/null || true

rustup toolchain install "$RUST_STABLE_TOOLCHAIN" --profile minimal >/dev/null 2>&1 || true

# ---- oracle builds (KAT probe + test-suite precompile), run CONCURRENTLY with the fuzz build ------
# (#1183, see REBUILD BUDGET above.) Exactly the commands, flags and outputs they had when they ran
# after the fuzz build; only the start time moves. They share no build directory with it: the fuzz
# build writes target/$TRIPLE/release (+ target/release for build scripts), these write
# mayhem/kat/target/debug and target/debug, with the stable toolchain. Each command sets its own
# RUSTFLAGS, so the fuzz build's exported ASan RUSTFLAGS never reach them. Their output goes to a log
# that is printed once the fuzz build is done; a failure in either half fails this script.
build_oracles() {
  echo "=== build mayhem/kat/ (KAT-probe crate; clean, non-sanitized, dynamically linked oracle) ==="
  # A small ADDITIVE crate (own empty [workspace] table — see mayhem/kat/Cargo.toml) built on the
  # STABLE toolchain (no ASan/nightly needed for an oracle binary) with the project's own path deps
  # (crates/wat, crates/wasmparser, crates/wasmprinter). Rust binaries are dynamically linked by
  # default (unlike Go) — no cgo-equivalent trick needed; we still assert it below as a regression
  # guard (§4 REQUIRED: a known-answer assertion through a dynamically linked binary).
  # mayhem/kat/Cargo.lock IS committed (git add -f — an upstream root .gitignore, if any, could
  # otherwise swallow it), so --locked here resolves purely from the $CARGO_HOME cache offline.
  # Dev profile (#1183): debug-assertions and overflow checks ON, like the graded fuzz binary
  # (`cargo fuzz build --debug-assertions`) and the test suite below, so a `cfg(debug_assertions)`
  # gate cannot split the probe from the graded binary; and an optimized build of three crates is
  # compile time the probe's one fixed module does not need.
  ( cd mayhem/kat && RUSTFLAGS="" cargo "+$RUST_STABLE_TOOLCHAIN" build --locked ) || return 1

  echo "=== precompile the workspace's own test suite (hermetic, normal non-sanitized flags, stable toolchain) ==="
  # Mirrors upstream CI's own exclusion list (.github/workflows/main.yml): wasmtime-dependent crates
  # have a MORE AGGRESSIVE MSRV than wasm-tools itself and are excluded from the default test pass.
  #
  # Two commands, MUST match test.sh exactly (so test.sh only RUNS, no recompile):
  #   (A) `-p wasm-tools --lib --bins` — the root package's OWN unit tests, explicitly WITHOUT its
  #       `tests/cli.rs` integration test ([[test]] name="cli", harness=false): that test drives the
  #       official WebAssembly spec testsuite via the `tests/testsuite` GIT SUBMODULE, which is not
  #       populated by a plain `git clone`/`docker build` context (submodule content lives in a
  #       SEPARATE repo, not as objects in this one) — verify-repo.sh's clean-clone build step would
  #       hit an empty tests/testsuite/ and fail. Skipping just this one integration test target
  #       keeps every other real test (1264+ across the workspace) as the oracle.
  #   (B) `--workspace --exclude wasm-tools <...>` — every other crate, default targets (lib + any
  #       integration tests + doctests) — these don't depend on the submodule.
  RUSTFLAGS="$TEST_RUSTFLAGS" cargo "+$RUST_STABLE_TOOLCHAIN" test -p wasm-tools --lib --bins --no-run --no-fail-fast --locked \
    --jobs "$MAYHEM_JOBS" || return 1
  RUSTFLAGS="$TEST_RUSTFLAGS" cargo "+$RUST_STABLE_TOOLCHAIN" test --workspace --no-run --no-fail-fast --locked \
    --exclude wasm-tools --exclude fuzz-stats --exclude wit-component --exclude wasm-mutate-stats \
    --exclude wit-dylib --exclude wit-dylib-ffi --exclude test-programs \
    --exclude wasm-tools-fuzz --exclude wit-parser-fuzz \
    --jobs "$MAYHEM_JOBS" || return 1
}
oracle_log="$(mktemp)"
build_oracles > "$oracle_log" 2>&1 &
oracle_pid=$!
echo "oracle builds (KAT probe, test-suite precompile) started in the background (pid $oracle_pid)"

echo "=== cargo fuzz build (image default nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "building fuzz binary: $BIN (fuzz-dir=$FUZZ_DIR)"

fuzz_rc=0
cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$BIN" || fuzz_rc=$?
# Always reap the oracle builds (no orphaned cargo left behind) and show their output.
oracle_rc=0
wait "$oracle_pid" || oracle_rc=$?
echo "=== oracle builds output (ran concurrently with the fuzz build) ==="
cat "$oracle_log"
rm -f "$oracle_log"
[ "$fuzz_rc" -eq 0 ] || { echo "ERROR: cargo fuzz build failed (rc=$fuzz_rc)" >&2; exit "$fuzz_rc"; }
[ "$oracle_rc" -eq 0 ] || { echo "ERROR: oracle build (KAT probe / test-suite precompile) failed (rc=$oracle_rc)" >&2; exit 1; }

bin="$SRC/target/$TRIPLE/release/$BIN"
[ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin (workspace-member fuzz dir writes to the WORKSPACE ROOT target/, not fuzz/target/ — check Cargo.toml [workspace] members)" >&2; exit 1; }
cp "$bin" "/mayhem/$BIN"
echo "built /mayhem/$BIN"
file "/mayhem/$BIN" | grep -q 'dynamically linked' && echo "OK: /mayhem/$BIN is dynamically linked" \
  || { echo "ERROR: /mayhem/$BIN is not dynamically linked" >&2; exit 1; }

kat_bin="mayhem/kat/target/debug/kat"
[ -x "$kat_bin" ] || { echo "ERROR: expected KAT probe binary not found at $kat_bin" >&2; exit 1; }
cp "$kat_bin" /mayhem/kat_probe
file /mayhem/kat_probe | grep -q 'dynamically linked' && echo "OK: /mayhem/kat_probe is dynamically linked" \
  || { echo "ERROR: /mayhem/kat_probe is not dynamically linked (KAT probe would be immune to the sabotage/oracle check)" >&2; exit 1; }

echo "build.sh: binaries:"
ls -la /mayhem/run /mayhem/kat_probe

echo "build.sh complete"
