(module
  (func (export "classify") (param $x i32) (result i32)
    (block $neg
      (block $zero
        (block $pos
          (br_table $neg $zero $pos (i32.add (i32.const 1) (i32.shr_s (i32.mul (local.get $x) (i32.const 1)) (i32.const 31))))
          )
        (return (i32.const 1)))
      (return (i32.const 0)))
    (i32.const -1))
  (func (export "select_br") (param $i i32) (result i32)
    (block $d (result i32)
      (block $c (result i32)
        (block $b (result i32)
          (block $a (result i32)
            (i32.const 100)
            (br_table $a $b $c $d (local.get $i)))
          (i32.add (i32.const 1)))
        (i32.add (i32.const 10)))
      (i32.add (i32.const 100))))
  (func (export "sum_to") (param $n i32) (result i32)
    (local $i i32) (local $s i32)
    (block $break
      (loop $continue
        (br_if $break (i32.gt_s (local.get $i) (local.get $n)))
        (local.set $s (i32.add (local.get $s) (local.get $i)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $continue)))
    (local.get $s))
  (func (export "nested_if") (param $a i32) (param $b i32) (result i32)
    (if (result i32) (local.get $a)
      (then (if (result i32) (local.get $b) (then (i32.const 3)) (else (i32.const 2))))
      (else (if (result i32) (local.get $b) (then (i32.const 1)) (else (i32.const 0))))))
  (func (export "flat_if") (param i32) (result i32)
    local.get 0
    if (result i32)
      i32.const 11
    else
      i32.const 22
    end)
  (func $pair (result i32 i32) (i32.const 7) (i32.const 9))
  (func (export "multi") (result i32)
    call $pair
    i32.sub)
  (func (export "block_params") (param $x i32) (result i32)
    local.get $x
    (block (param i32) (result i32)
      i32.const 5
      i32.add)
    i32.const 2
    i32.mul)
  (func (export "early") (param $x i32) (result i32)
    (if (i32.lt_s (local.get $x) (i32.const 0)) (then (return (i32.const -1))))
    (i32.const 1))
  (func (export "sel") (param i32 i32 i32) (result i32)
    (select (local.get 0) (local.get 1) (local.get 2)))
  (func (export "dead") (result i32)
    (block (result i32)
      (br 0 (i32.const 5))
      (i32.const 99)
      drop
      (i32.const 6)
      drop
      unreachable)))
