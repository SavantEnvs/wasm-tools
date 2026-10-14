#![no_main]

// Feeds raw bytes to `wasm-mutate` the way an embedder's mutation hook does (e.g. Wasmtime's
// fuzzers): the first 8 bytes are the RNG seed, the rest is a Wasm binary that is NOT validated
// first. Any error is fine; a panic is a finding.
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    if data.len() < 8 {
        return;
    }
    let (seed, wasm) = data.split_at(8);
    let mut mutator = wasm_mutate::WasmMutate::default();
    mutator.seed(u64::from_le_bytes(seed.try_into().unwrap()));
    mutator.fuel(300);
    let Ok(iter) = mutator.run(wasm) else {
        return;
    };
    for mutated in iter.take(10) {
        let _ = mutated;
    }
});
