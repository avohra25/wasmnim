(module
  (func (export "fac") (param $n i64) (result i64)
    (local $acc i64)
    (local.set $acc (i64.const 1))
    (block $exit
      (loop $top
        (br_if $exit (i64.le_u (local.get $n) (i64.const 1)))
        (local.set $acc (i64.mul (local.get $acc) (local.get $n)))
        (local.set $n (i64.sub (local.get $n) (i64.const 1)))
        (br $top)))
    (local.get $acc))
  (func $gcd (export "gcd") (param $a i32) (param $b i32) (result i32)
    (if (result i32) (i32.eqz (local.get $b))
      (then (local.get $a))
      (else (call $gcd (local.get $b) (i32.rem_u (local.get $a) (local.get $b))))))
  (func (export "collatz_steps") (param $n i64) (result i32)
    (local $steps i32)
    (loop $l
      (if (i64.ne (local.get $n) (i64.const 1))
        (then
          (local.set $n
            (if (result i64) (i64.eqz (i64.and (local.get $n) (i64.const 1)))
              (then (i64.shr_u (local.get $n) (i64.const 1)))
              (else (i64.add (i64.mul (local.get $n) (i64.const 3)) (i64.const 1)))))
          (local.set $steps (i32.add (local.get $steps) (i32.const 1)))
          (br $l))))
    (local.get $steps)))
