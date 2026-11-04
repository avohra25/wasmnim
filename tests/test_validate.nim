import std/[unittest, os, strutils]
import ../src/wasmnim
import helpers

const corpusDir = currentSourcePath().parentDir / "corpus"

proc check(src: string): bool =
  ## true when the module validates
  var m = parseWat(src)
  try:
    validate(m)
    true
  except ValidationError:
    false

proc rejects(src: string, fragment = ""): bool =
  var m = parseWat(src)
  try:
    validate(m)
    false
  except ValidationError as e:
    fragment.len == 0 or fragment in e.msg

template fn(sig, body: string): string = "(module " & "(func " & sig & " " & body & "))"

suite "validate: accepted programs":
  for f in walkFiles(corpusDir / "*.wat"):
    test "corpus " & f.splitFile.name:
      var m = parseWat(readFile(f))
      validate(m)
      for b in m.bodies: check b.validated
  test "validation is idempotent":
    var m = parseWat(readFile(corpusDir / "control.wat"))
    validate(m)
    let once = m
    validate(m)
    check m.bodies.len == once.bodies.len
    for i in 0 ..< m.bodies.len:
      check m.bodies[i].code == once.bodies[i].code

suite "validate: operand stack typing":
  test "stack underflow":
    check rejects(fn("(result i32)", "(i32.add (i32.const 1))"))
    check rejects(fn("", "drop"))
  test "type mismatches":
    check rejects(fn("(result i32)", "(i32.add (i32.const 1) (i64.const 2))"))
    check rejects(fn("(result i32)", "(f32.const 1)"))
    check rejects(fn("(param i32) (result i64)", "(local.get 0)"))
  test "leftover values":
    check rejects(fn("", "(i32.const 1)"))
    check rejects(fn("(result i32)", "(i32.const 1) (i32.const 2)"))
  test "missing results":
    check rejects(fn("(result i32)", "nop"))
  test "select operands must agree":
    check rejects(fn("(result i32)", "(select (i32.const 1) (i64.const 2) (i32.const 0))"))
    check check(fn("(result i64)", "(select (i64.const 1) (i64.const 2) (i32.const 0))"))
  test "unreachable code is polymorphic":
    check check(fn("(result i32)", "unreachable"))
    check check(fn("(result i32)", "unreachable i32.add"))
    check check(fn("(result i32)", "(return (i32.const 1)) i32.add"))
    check rejects(fn("(result i32)", "unreachable (i64.const 1)"))

suite "validate: control flow":
  test "unknown labels":
    check rejects(fn("", "(br 1)"))
    check rejects(fn("", "(block (br 2))"))
  test "branch values must match the target's type":
    check rejects(fn("(result i32)", "(block (result i32) (br 0 (i64.const 1)))"))
    check check(fn("(result i32)", "(block (result i32) (br 0 (i32.const 1)))"))
  test "br_table targets need identical arities":
    check rejects("""(module (func (result i32)
      (block (result i32) (block (br_table 0 1 (i32.const 0))) (i32.const 1))))""")
  test "if branches must both produce the declared type":
    check rejects(fn("(param i32) (result i32)", "(if (result i32) (local.get 0) (then (i32.const 1)))"))
    check check(fn("(param i32) (result i32)", "(if (result i32) (local.get 0) (then (i32.const 1)) (else (i32.const 2)))"))
  test "if condition must be i32":
    check rejects(fn("", "(if (i64.const 1) (then))"))
  test "loop labels carry parameters, not results":
    check check(fn("", "(loop (br 0))"))
    check check(fn("(result i32)", "(block (result i32) (loop (result i32) (i32.const 1)))"))

suite "validate: calls, locals and globals":
  test "unknown functions, locals and globals":
    check rejects(fn("", "(call 5)"))
    check rejects(fn("", "(drop (local.get 3))"))
    check rejects(fn("", "(drop (global.get 0))"))
  test "arguments are checked":
    check rejects("(module (func $f (param i32)) (func (call $f (i64.const 1))))")
    check rejects("(module (func $f (param i32)) (func (call $f)))")
  test "local.set type":
    check rejects(fn("(local i32)", "(local.set 0 (f32.const 1))"))
  test "global.set needs a mutable global":
    check rejects("(module (global i32 (i32.const 0)) (func (global.set 0 (i32.const 1))))", "immutable")
    check check("(module (global (mut i32) (i32.const 0)) (func (global.set 0 (i32.const 1))))")
  test "call_indirect needs a table":
    check rejects("(module (type $t (func)) (func (call_indirect (type $t) (i32.const 0))))")

suite "validate: memory":
  test "memory instructions need a memory":
    check rejects(fn("(result i32)", "(i32.load (i32.const 0))"))
    check rejects(fn("(result i32)", "memory.size"))
  test "alignment may not exceed the natural alignment":
    check rejects("(module (memory 1) (func (drop (i32.load align=8 (i32.const 0)))))", "alignment")
    check rejects("(module (memory 1) (func (drop (i32.load8_u align=2 (i32.const 0)))))", "alignment")
    check check("(module (memory 1) (func (drop (i64.load align=8 (i32.const 0)))))")
  test "store operand types":
    check rejects("(module (memory 1) (func (i32.store (i32.const 0) (i64.const 1))))")

suite "validate: module level":
  test "at most one memory and one table":
    check rejects("(module (memory 1) (memory 1))")
    check rejects("(module (table 1 funcref) (table 1 funcref))")
  test "limits":
    check rejects("(module (memory 5 2))", "exceeds its maximum")
    check rejects("(module (memory 65537))")
  test "duplicate exports":
    check rejects("""(module (func $f) (export "a" (func $f)) (export "a" (func $f)))""", "duplicate")
  test "start function must take nothing and return nothing":
    check rejects("(module (func $s (param i32)) (start $s))", "start")
    check rejects("(module (func $s (result i32) (i32.const 1)) (start $s))", "start")
  test "global initialisers":
    check rejects("(module (global i32 (i64.const 1)))")
    check rejects("(module (global (mut i32) (i32.const 0)) (global i32 (global.get 0)))")
    check check("""(module (import "m" "g" (global i32)) (global i32 (global.get 0)))""")
  test "segment offsets must be i32":
    check rejects("(module (memory 1) (data (i64.const 0) \"x\"))")
    check rejects("(module (table 1 funcref) (func $f) (elem (f32.const 0) $f))")
  test "segments need a memory or table":
    check rejects("(module (data (i32.const 0) \"x\"))")

suite "validate: branch resolution":
  test "branches are rewritten to absolute targets with arity and height":
    var m = parseWat("""(module (func (param i32) (result i32)
      (block (result i32)
        (i32.const 7)
        (br_if 0 (local.get 0))
        drop
        (i32.const 9))))""")
    validate(m)
    var found = false
    for ins in m.bodies[0].code:
      if ins.op == opBrIf:
        found = true
        check ins.y == 1                        # carries one value
        check ins.x < uint64(m.bodies[0].code.len)
        check m.bodies[0].code[int(ins.x) - 1].op == opEnd   # lands just past `end`
    check found
  test "maxHeight covers the deepest operand stack":
    var m = parseWat("(module (func (result i32) (i32.add (i32.add (i32.const 1) (i32.const 2)) (i32.mul (i32.const 3) (i32.const 4)))))")
    validate(m)
    check m.bodies[0].maxHeight == 3
