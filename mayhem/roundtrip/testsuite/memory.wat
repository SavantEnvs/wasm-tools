(module
  (memory 1)
  (data (i32.const 0) "hello")
  (func $len (result i32) i32.const 5)
  (export "memory" (memory 0))
  (export "len" (func $len)))
