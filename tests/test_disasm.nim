import std/[unittest, strutils]
import ../src/wasmnim
import helpers

proc roundTrip(src: string): string =
  let m = parseWat(src)
  let text = disassemble(m)
  let again = parseWat(text)
  check encodeModule(again) == encodeModule(m)
  var checked = again            # validation rewrites branches, so check a copy
  validate(checked)
  text

suite "disassembler":
  test "prints structured control flow with indentation":
    let text = roundTrip("""(module (func (export "f") (param i32) (result i32)
      (if (result i32) (local.get 0)
        (then (i32.const 1))
        (else (block (result i32) (i32.const 2) (br 0))))))""")
    check "        i32.const 2\n        br 0" in text
    check "      else\n" in text or "    else\n" in text

  test "memory arguments only show non-default alignment":
    let text = roundTrip("""(module (memory 1) (func (param i32) (result i32)
      (i32.add (i32.load offset=8 (local.get 0)) (i32.load align=1 (local.get 0)))))""")
    check "i32.load offset=8\n" in text
    check "i32.load align=1\n" in text

  test "floats keep their exact bits":
    let consts = [
      "f32.const nan", "f32.const -nan", "f32.const nan:0x200001", "f32.const -inf",
      "f32.const -0.0", "f32.const 1e-45", "f32.const 3.4028235e38", "f32.const 0.1",
      "f64.const nan:0x4_0000_0000_0001", "f64.const -0.0", "f64.const 5e-324",
      "f64.const 1.7976931348623157e308", "f64.const 0.1", "f64.const inf"]
    for c in consts:
      discard roundTrip("(module (func (result " & c.split('.')[0] & ") " & c & "))")

  test "integers print signed":
    let text = roundTrip("(module (func (result i64) i64.const 0xFFFFFFFFFFFFFFFF drop i32.const 0x80000000 drop i64.const 5))")
    check "i64.const -1" in text
    check "i32.const -2147483648" in text

  test "all module sections survive":
    let text = roundTrip("""(module
      (type $t (func (param i32) (result i32)))
      (import "m" "n" (func (type $t)))
      (import "m" "g" (global (mut i64)))
      (memory 1 3) (table 4 funcref)
      (global $c i32 (i32.const 7))
      (func $a (type $t) (local.get 0))
      (elem (i32.const 1) $a $a)
      (data (i32.const 8) "hi\00\ff\"\\")
      (export "a" (func $a)) (export "mem" (memory 0))
      (start $s) (func $s))""")
    for needle in ["(import \"m\" \"n\"", "(mut i64)", "(memory 1 3)", "(table 4 funcref)",
                   "(start ", "\\00\\ff\\22\\5c", "(elem (table 0)"]:
      check needle in text

  test "call_indirect and br_table keep their operands":
    discard roundTrip("""(module (type $b (func (param i32)))
      (table 2 funcref) (func $f (type $b))
      (func (param i32) (block (block (br_table 0 1 0 (local.get 0))))
        (call_indirect (type $b) (i32.const 0) (i32.const 1))))""")

  test "binary modules disassemble and reassemble":
    for name in ["sieve", "traps", "memory", "imports"]:
      let data = hexBytes(readFile("tests/corpus/" & name & ".wasm.hex"))
      var m = decodeModule(data)
      m.customs.setLen(0)        # the text form drops custom sections such as `name`
      let again = parseWat(disassemble(m))
      check encodeModule(again) == encodeModule(m)
