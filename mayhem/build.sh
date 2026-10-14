#!/usr/bin/env bash
#
# mayhem/build.sh — mining branch on BASE 3226b14: build the additive `mutate_raw` cargo-fuzz binary
# (mayhem/mutate_raw_fuzz/: raw bytes straight into wasm-mutate, the code fix ebd4b68 changed) as an ASan libFuzzer binary, and the additive mayhem/kat/ probe
# (a clean, dynamically linked oracle binary) that mayhem/test.sh asserts on.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE; the first (online)
# build populates the cargo registry under $CARGO_HOME. Do NOT pass --offline here.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

RUST_STABLE_TOOLCHAIN="${RUST_STABLE_TOOLCHAIN:-1.88.0}"

cd "$SRC"

FUZZ_DIR="mayhem/mutate_raw_fuzz"
TRIPLE="x86_64-unknown-linux-gnu"
BIN="mutate_raw"

RUST_SAN="-Zsanitizer=address"
[ -z "${SANITIZER_FLAGS+x}" ] || [ -n "${SANITIZER_FLAGS}" ] || RUST_SAN=""
RUST_DEBUG_FLAGS="${RUST_DEBUG_FLAGS:--Cdebuginfo=1 -Zdwarf-version=3}"
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing $RUST_SAN $RUST_DEBUG_FLAGS -Cforce-frame-pointers"
# Prebuilt libFuzzer runtime from the base image (no DWARF-5 CUs, no from-source compile).
export CUSTOM_LIBFUZZER_PATH=/usr/lib/llvm-19/lib/clang/19/lib/linux/libclang_rt.fuzzer-x86_64.a

find "$RUSTUP_HOME"/toolchains/*/lib/rustlib/"$TRIPLE"/lib \
  -name 'librustc-*_rt.*.a' -exec objcopy --strip-debug {} \; 2>/dev/null || true

rustup toolchain install "$RUST_STABLE_TOOLCHAIN" --profile minimal >/dev/null 2>&1 || true

echo "=== cargo fuzz build $BIN (ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$BIN"

bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$BIN"
[ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
cp "$bin" "/mayhem/$BIN"
file "/mayhem/$BIN" | grep -q 'dynamically linked' && echo "OK: /mayhem/$BIN is dynamically linked" \
  || { echo "ERROR: /mayhem/$BIN is not dynamically linked" >&2; exit 1; }

echo "=== build mayhem/kat/ (KAT probe; clean, non-sanitized, dynamically linked oracle) ==="
( cd mayhem/kat && RUSTFLAGS="" cargo "+$RUST_STABLE_TOOLCHAIN" build --locked )
kat_bin="mayhem/kat/target/debug/kat"
[ -x "$kat_bin" ] || { echo "ERROR: expected KAT probe binary not found at $kat_bin" >&2; exit 1; }
cp "$kat_bin" /mayhem/kat_probe
file /mayhem/kat_probe | grep -q 'dynamically linked' && echo "OK: /mayhem/kat_probe is dynamically linked" \
  || { echo "ERROR: /mayhem/kat_probe is not dynamically linked" >&2; exit 1; }

ls -la /mayhem/$BIN /mayhem/kat_probe
echo "build.sh complete"
