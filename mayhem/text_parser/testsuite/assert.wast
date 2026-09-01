(module
  (func $f (param i32) (result i32)
    local.get 0))

(assert_invalid
  (module (func $g (result i32)))
  "type mismatch")
