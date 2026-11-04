import std/[unittest, os, strutils]
import ../src/wasmnim
import ../src/wasmnim/encode
import ../src/wasmnim/wat
import helpers

const corpusDir = currentSourcePath().parentDir / "corpus"

proc corpusNames(): seq[string] =
  for f in walkFiles(corpusDir / "*.wat"):
    result.add f.splitFile.name

proc wasmtimeBytes(name: string): seq[byte] =
  hexBytes(readFile(corpusDir / name & ".wasm.hex").strip())

proc withoutNames(m: Module): Module =
  ## wasmtime attaches a "name" custom section holding the $identifiers; the
  ## text parser keeps names only for resolution, so compare without it.
  result = m
  result.customs.setLen(0)
  for c in m.customs:
    if c.name != "name": result.customs.add c

proc parses(src: string): Module = parseWat(src)

suite "wat: differential against the wasmtime assembler":
  for name in corpusNames():
    test name & " assembles to the same bytes as wasmtime":
      let m = parseWat(readFile(corpusDir / name & ".wat"))
      check encodeModule(m) == encodeModule(withoutNames(decodeModule(wasmtimeBytes(name))))

    test name & " survives decode then encode":
      let bytes = wasmtimeBytes(name)
      check encodeModule(decodeModule(bytes)) == bytes

suite "wat: syntax":
  test "comments and whitespace":
    let m = parses("""
      (; block (; nested ;) comment ;)
      (module ;; line comment
        (func (export "f") (result i32) i32.const 1))""")
    check m.funcs.len == 1
    check m.exports[0].name == "f"

  test "named and numeric indices agree":
    let a = parses("""(module (func $f (result i32) i32.const 1)
      (func (export "g") (result i32) call $f))""")
    let b = parses("""(module (func (result i32) i32.const 1)
      (func (export "g") (result i32) call 0))""")
    check encodeModule(a) == encodeModule(b)

  test "folded and flat forms are equivalent":
    let a = parses("""(module (func (param i32 i32) (result i32)
      (i32.add (local.get 0) (i32.mul (local.get 1) (i32.const 2)))))""")
    let b = parses("""(module (func (param i32 i32) (result i32)
      local.get 0 local.get 1 i32.const 2 i32.mul i32.add))""")
    check encodeModule(a) == encodeModule(b)

  test "a module with no wrapper is accepted as bare fields":
    let m = parses("(func (export \"x\"))")
    check m.funcs.len == 1

  test "string escapes":
    let m = parses("""(module (memory 1) (data (i32.const 0) "a\41\n\u{20ac}"))""")
    check m.datas[0].bytes == @[byte 'a'.ord, 0x41, 10, 0xE2, 0x82, 0xAC]

  test "integer literal forms":
    let m = parses("""(module (func (result i64)
      i64.const 0x7fff_ffff_ffff_ffff
      i64.const -0x8000_0000_0000_0000
      i64.add))""")
    check m.bodies.len == 1

  test "type uses are shared across identical signatures":
    let m = parses("""(module
      (func (param i32) (result i32) local.get 0)
      (func (param i32) (result i32) local.get 0)
      (func (result i32) i32.const 0))""")
    check m.types.len == 2

suite "wat: errors":
  proc fails(src: string): bool =
    try:
      discard parseWat(src)
    except WasmError:
      return true
    false

  test "unknown instruction":
    check fails("(module (func i32.frobnicate))")
  test "unknown label":
    check fails("(module (func br $nowhere))")
  test "unknown function name":
    check fails("(module (func call $missing))")
  test "unbalanced parentheses":
    check fails("(module (func)")
  test "bad string escape":
    check fails("(module (memory 1) (data (i32.const 0) \"\\q\"))")
  test "integer out of range":
    check fails("(module (func (result i32) i32.const 4294967296))")
  test "duplicate identifier":
    check fails("(module (func $a) (func $a))")
