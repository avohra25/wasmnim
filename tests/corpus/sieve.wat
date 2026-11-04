;; Sieve of Eratosthenes over linear memory: one byte per number.
(module
  (memory (export "mem") 1)
  (func (export "count_primes") (param $n i32) (result i32)
    (local $i i32) (local $j i32) (local $count i32)
    (memory.fill (i32.const 0) (i32.const 1) (i32.add (local.get $n) (i32.const 1)))
    (i32.store8 (i32.const 0) (i32.const 0))
    (i32.store8 (i32.const 1) (i32.const 0))
    (local.set $i (i32.const 2))
    (block $done
      (loop $outer
        (br_if $done (i32.gt_u (i32.mul (local.get $i) (local.get $i)) (local.get $n)))
        (if (i32.load8_u (local.get $i))
          (then
            (local.set $j (i32.mul (local.get $i) (local.get $i)))
            (block $inner_done
              (loop $inner
                (br_if $inner_done (i32.gt_u (local.get $j) (local.get $n)))
                (i32.store8 (local.get $j) (i32.const 0))
                (local.set $j (i32.add (local.get $j) (local.get $i)))
                (br $inner)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $outer)))
    (local.set $i (i32.const 0))
    (loop $count_loop
      (local.set $count (i32.add (local.get $count) (i32.load8_u (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $count_loop (i32.le_u (local.get $i) (local.get $n))))
    (local.get $count)))
