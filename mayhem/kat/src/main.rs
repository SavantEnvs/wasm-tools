// mayhem/kat — a small, ADDITIVE known-answer-test probe. Built clean (no sanitizer, stable
// toolchain) and dynamically linked (verified by build.sh via `file | grep dynamically linked`).
// This is the REQUIRED behavioral oracle (SPEC §6.3 / net-new brief §4): a fixed input goes
// through the exact same upstream API the fuzz harness exercises (wat::parse_str,
// wasmparser::validate, wasmprinter::print_bytes) and every intermediate value is asserted
// EXACTLY — a panic (nonzero exit, e.g. under the sabotage/neuter shim) or any value mismatch is
// a hard failure. This is unconditional: no `if -f seed` guards, nothing skipped.

const WAT_SRC: &str = r#"(module
  (func $add (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add)
  (export "add" (func $add)))
"#;

// Filled in from a real build (see build.sh output) — this is the fixed known-answer value, not
// a placeholder computed at runtime.
const EXPECTED_WASM_HEX: &str =
    "0061736d0100000001070160027f7f017f030201000707010361646400000a09010700200020016a0b000d046e616d650106010003616464";
// Captured from a real build (mayhem/kat_probe run inside the pinned toolchain) and hardcoded
// here as the known-answer golden value.
const EXPECTED_PRINT: &str = "(module\n  (type (;0;) (func (param i32 i32) (result i32)))\n  (export \"add\" (func $add))\n  (func $add (;0;) (type 0) (param i32 i32) (result i32)\n    local.get 0\n    local.get 1\n    i32.add\n  )\n)\n";

fn to_hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{:02x}", b));
    }
    s
}

fn main() {
    // 1) wat::parse_str — the WAT text-format parser (task's second entry point).
    let wasm = wat::parse_str(WAT_SRC).expect("wat::parse_str failed on a known-good module");
    assert_eq!(&wasm[0..8], b"\0asm\x01\0\0\0", "wasm magic/version header mismatch");
    let hex = to_hex(&wasm);
    assert_eq!(hex, EXPECTED_WASM_HEX, "encoded wasm bytes do not match the known-answer hex");
    println!("KAT_WASM_LEN={}", wasm.len());
    println!("KAT_WASM_HEX={}", hex);

    // 2) wasmparser::validate — the validator/parser on a raw wasm binary byte buffer (task's
    //    first entry point). A KNOWN-GOOD module must validate.
    wasmparser::validate(&wasm).expect("a known-good module failed to validate");
    println!("KAT_VALIDATE=ok");

    // 3) wasmprinter — binary -> text, asserted against an EXACT golden string (a real assertion
    //    on computed output, not just "didn't crash").
    let text = wasmprinter::print_bytes(&wasm).expect("wasmprinter failed to print a valid module");
    assert_eq!(text, EXPECTED_PRINT, "printed WAT text does not match the known-answer golden string");
    println!("KAT_PRINT_LEN={}", text.len());

    // 4) Negative case: the validator/parser is a SECURITY-SENSITIVE boundary against untrusted
    //    input — it must REJECT a malformed module. Take the known-good module and append a
    //    bogus section id (0xFF is not a valid core-wasm section id 0..=12).
    let mut bad = wasm.clone();
    bad.push(0xFF);
    bad.push(0x01);
    bad.push(0x00);
    // `wasmparser::validate`'s Ok type (`Types`) isn't `Debug`, so use an explicit match instead
    // of `.expect_err(...)` (which requires `T: Debug`).
    let err = match wasmparser::validate(&bad) {
        Ok(_) => panic!("a malformed module unexpectedly validated"),
        Err(e) => e,
    };
    println!("KAT_REJECT=ok err={}", err);

    println!("KAT_OK");
}
