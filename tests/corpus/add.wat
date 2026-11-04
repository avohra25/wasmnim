;; Flat and folded forms of the same function, named and numeric locals.
(module
  (func $add (export "add") (param $a i32) (param $b i32) (result i32)
    local.get $a
    local.get $b
    i32.add)
  (func (export "add_folded") (param i32 i32) (result i32)
    (i32.add (local.get 0) (local.get 1)))
  (func (export "add3") (param i32 i32 i32) (result i32)
    (call $add (call $add (local.get 0) (local.get 1)) (local.get 2)))
  (func (export "answer") (result i32) (i32.const 42))
  (func (export "inc_all") (param $x i64) (result i64)
    (i64.add (local.get $x) (i64.const 1))))
