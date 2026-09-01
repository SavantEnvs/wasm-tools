#!/usr/bin/env bash
#
# mayhem/test.sh — run TWO layered oracles (net-new brief §4: `cargo test` alone is NOT enough,
# because a statically-something/neutered process surviving sabotage would otherwise pass silently
# — so we ALSO run a dynamically linked KAT probe and assert its EXACT stdout):
#
#   1. The workspace's own `cargo test` suite (already precompiled by mayhem/build.sh with the
#      STABLE toolchain + matching flags, so this just RUNS — no recompile here).
#   2. /mayhem/kat_probe — a small KAT probe (mayhem/kat/) that runs a fixed WAT module through
#      wat::parse_str -> wasmparser::validate -> wasmprinter::print_bytes and asserts EXACT
#      known-answer values (see mayhem/kat/src/main.rs), plus a negative (malformed-input-rejected)
#      case. Its output is asserted byte-for-byte here in bash — outside the sanitized/neutered
#      process — so sabotage cannot hide inside it.
#
# exit 0 = pass. Emits a CTRF summary (both layers folded into one report: 2 "tests").
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
RUST_STABLE_TOOLCHAIN="${RUST_STABLE_TOOLCHAIN:-1.88.0}"
# Same dev/test profile debuginfo as mayhem/build.sh's precompile (see its REBUILD BUDGET note), so
# cargo finds the test binaries current and only runs them.
export CARGO_PROFILE_DEV_DEBUG=line-tables-only
# Same linker flag as build.sh's precompile (lld; changes no generated code), for the same reason.
TEST_RUSTFLAGS="-Clink-arg=-fuse-ld=lld"
# build.sh exports this for libfuzzer-sys (a dev-dependency of wasm-smith, so it is in the test
# build too), and libfuzzer-sys's build script declares rerun-if-env-changed on it. Without the same
# value here cargo would rebuild libfuzzer-sys and wasm-smith's tests on every test.sh run (and
# build.sh would rebuild them back). It only selects the prebuilt libFuzzer archive; no test changes.
export CUSTOM_LIBFUZZER_PATH=/usr/lib/llvm-19/lib/clang/19/lib/linux/libclang_rt.fuzzer-x86_64.a
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

overall_failed=0

# ---- layer 1: workspace `cargo test` (mirrors upstream's own MSRV exclusion list; MUST match
#      build.sh's precompile invocation exactly so cargo sees the build as current — TWO commands:
#      (A) wasm-tools' own lib+bin tests, explicitly WITHOUT its tests/cli.rs integration test
#      (needs the unpopulated tests/testsuite git submodule — see build.sh's comment), and
#      (B) every other crate's default targets) -------------------------------------------------
echo "=== layer 1: cargo test (stable toolchain) ==="
outA="$(RUSTFLAGS="$TEST_RUSTFLAGS" cargo "+$RUST_STABLE_TOOLCHAIN" test -p wasm-tools --lib --bins --no-fail-fast --locked \
        --jobs "$MAYHEM_JOBS" 2>&1)"
rcA=$?
echo "$outA"
outB="$(RUSTFLAGS="$TEST_RUSTFLAGS" cargo "+$RUST_STABLE_TOOLCHAIN" test --workspace --no-fail-fast --locked \
        --exclude wasm-tools --exclude fuzz-stats --exclude wit-component --exclude wasm-mutate-stats \
        --exclude wit-dylib --exclude wit-dylib-ffi --exclude test-programs \
        --exclude wasm-tools-fuzz --exclude wit-parser-fuzz \
        --jobs "$MAYHEM_JOBS" 2>&1)"
rcB=$?
echo "$outB"
out="$outA
$outB"
rc1=$rcA
[ "$rcB" -eq 0 ] || rc1=$rcB

passed=0; failed=0; skipped=0
while read -r p f s; do
  passed=$((passed + p)); failed=$((failed + f)); skipped=$((skipped + s))
done < <(echo "$out" | grep -oE '[0-9]+ passed; [0-9]+ failed;.*[0-9]+ ignored' \
            | sed -E 's/([0-9]+) passed; ([0-9]+) failed;.*?([0-9]+) ignored/\1 \2 \3/')

if [ "$passed" -eq 0 ] && [ "$failed" -eq 0 ]; then
  echo "test.sh: layer 1 — could not parse any 'cargo test' result line — treating as a hard failure" >&2
  failed=1
fi
if [ "$rc1" -ne 0 ] && [ "$failed" -eq 0 ]; then
  failed=1
fi
[ "$failed" -eq 0 ] || overall_failed=1
echo "layer 1: passed=$passed failed=$failed skipped=$skipped rc=$rc1"

# ---- layer 2: the KAT probe — assert EXACT stdout, unconditionally (no existence guard) --------
echo "=== layer 2: /mayhem/kat_probe (known-answer test) ==="
kat_bin="/mayhem/kat_probe"
kat_failed=0
if [ ! -x "$kat_bin" ]; then
  echo "test.sh: layer 2 — $kat_bin missing or not executable (build.sh should have produced it)" >&2
  kat_failed=1
  kat_out=""
else
  kat_out="$("$kat_bin" 2>&1)"; kat_rc=$?
  echo "$kat_out"
  # Every one of these markers MUST be present, in this exact form, with the exact known-answer
  # values baked into mayhem/kat/src/main.rs. A neutered/no-op binary (e.g. under the sabotage
  # shim's _exit(0) before printing anything) produces EMPTY stdout, which fails every grep below.
  if [ "$kat_rc" -ne 0 ]; then
    echo "test.sh: layer 2 — kat_probe exited $kat_rc (expected 0)" >&2
    kat_failed=1
  fi
  echo "$kat_out" | grep -qF 'KAT_VALIDATE=ok'  || { echo "test.sh: layer 2 — missing KAT_VALIDATE=ok" >&2; kat_failed=1; }
  echo "$kat_out" | grep -qF 'KAT_REJECT=ok'    || { echo "test.sh: layer 2 — missing KAT_REJECT=ok (malformed-module rejection)" >&2; kat_failed=1; }
  echo "$kat_out" | grep -qF 'KAT_OK'           || { echo "test.sh: layer 2 — missing final KAT_OK marker" >&2; kat_failed=1; }
fi
[ "$kat_failed" -eq 0 ] || overall_failed=1
echo "layer 2: kat_failed=$kat_failed"

# Fold both layers into one CTRF summary: 2 "tests" (one per layer), each pass/fail as a whole.
l1_pass=$([ "$failed" -eq 0 ] && echo 1 || echo 0)
l2_pass=$([ "$kat_failed" -eq 0 ] && echo 1 || echo 0)
ctrf_passed=$((l1_pass + l2_pass))
ctrf_failed=$((2 - ctrf_passed))
emit_ctrf "cargo-test+kat-probe" "$ctrf_passed" "$ctrf_failed"
