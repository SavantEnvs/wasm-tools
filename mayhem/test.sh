#!/usr/bin/env bash
#
# mayhem/test.sh — mining branch on BASE b19ce51: the KAT probe (mayhem/kat/) runs a fixed WAT module
# through wat::parse_str -> wasmparser::validate -> wasmprinter::print_bytes and asserts EXACT
# known-answer values (see mayhem/kat/src/main.rs) plus a malformed-input rejection. Its stdout is
# asserted here in bash, outside the sanitized/neutered process, so a no-op binary fails.
# exit 0 = pass. Emits a CTRF summary.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
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

if [ "$kat_failed" -eq 0 ]; then emit_ctrf "kat-probe" 1 0; else emit_ctrf "kat-probe" 0 1; fi
