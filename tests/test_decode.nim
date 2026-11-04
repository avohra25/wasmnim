import std/strutils
import std/unittest
import wasmnim, helpers

const
  answerHex = "0061736d010000000105016000017f03020100070a0106616e7377657200000a06010400412a0b"
  importsHex = "0061736d0100000001050160017f0002200303656e76036c6f67000003656e76036d656d0201010403656e760167037f000302010007060102676f00010a08010600200010000b000d046e616d6501060100036c6f67"
  mixedHex = "0061736d01000000010a0260027f7e017c60000003030200010404017000030504010101020606017f0141050b070b02036d656d0200016600000801010908010041000b0200000a1e021902027d017f027f41010e0100000b1a44000000000000f83f0b02000b0b0b010041080b0568656c6c6f001a046e616d65010702000166010173040401000174070401000167"

suite "binary decoder":
  test "empty module":
    let m = decodeModule(hexBytes("0061736d01000000"))
    check m.types.len == 0 and m.funcs.len == 0

  test "answer module":
    let m = decodeModule(hexBytes(answerHex))
    check m.types.len == 1
    check m.types[0].params.len == 0
    check m.types[0].results == @[vtI32]
    check m.funcs == @[0'u32]
    check m.exports.len == 1 and m.exports[0].name == "answer"
    check m.exports[0].kind == ekFunc
    check m.bodies.len == 1
    let code = m.bodies[0].code
    check code.len == 2
    check code[0].op == opI32Const and code[0].x == 42
    check code[1].op == opEnd

  test "imports of every kind":
    let m = decodeModule(hexBytes(importsHex))
    check m.imports.len == 3
    check m.imports[0].module == "env" and m.imports[0].name == "log"
    check m.imports[0].kind == ekFunc and m.imports[0].typeIdx == 0
    check m.imports[1].kind == ekMemory
    check m.imports[1].mem.min == 1 and m.imports[1].mem.hasMax and m.imports[1].mem.max == 4
    check m.imports[2].kind == ekGlobal
    check m.imports[2].global.vt == vtI32 and not m.imports[2].global.mut
    check m.numFuncs == 2
    check m.customs.len == 1 and m.customs[0].name == "name"

  test "memory, table, globals, data, elements, start":
    let m = decodeModule(hexBytes(mixedHex))
    check m.types.len == 2
    check m.types[0].params == @[vtI32, vtI64] and m.types[0].results == @[vtF64]
    check m.mems.len == 1 and m.mems[0].hasMax and m.mems[0].max == 2
    check m.tables.len == 1 and m.tables[0].min == 3
    check m.globals.len == 1 and m.globals[0].gt.mut and m.globals[0].init.bits == 5
    check m.datas.len == 1 and m.datas[0].bytes == toBytes("hello")
    check m.datas[0].offset.bits == 8
    check m.elems.len == 1 and m.elems[0].funcs == @[0'u32, 0'u32]
    check m.hasStart and m.start == 1
    check m.bodies[0].locals == @[vtF32, vtF32, vtI32]
    var idx: uint32
    check m.findExport("mem", ekMemory, idx) and idx == 0
    check m.findExport("f", ekFunc, idx) and idx == 0
    check not m.findExport("nope", ekFunc, idx)

  test "block types and br_table immediates":
    let m = decodeModule(hexBytes(mixedHex))
    let code = m.bodies[0].code
    check code[0].op == opBlock and code[0].y == 1 and code[0].x == uint64(ord(vtI32))
    check code[2].op == opBrTable
    let t = m.bodies[0].brTables[int(code[2].x)]
    check t.len == 2 and t[0].pc == 0 and t[1].pc == 0

  test "bad magic and version":
    expect DecodeError: discard decodeModule(hexBytes("0061736e01000000"))
    expect DecodeError: discard decodeModule(hexBytes("0061736d02000000"))
    expect DecodeError: discard decodeModule(hexBytes("0061"))

  test "truncated modules never crash":
    let full = hexBytes(mixedHex)
    for n in 0 ..< full.len:
      try:
        discard decodeModule(full[0 ..< n])
        # a prefix may be a valid module only when cut on a section boundary
      except DecodeError:
        discard

  test "single byte corruptions are rejected or decode, never crash":
    let full = hexBytes(mixedHex)
    for i in 0 ..< full.len:
      for delta in [1'u8, 0x80, 0xFF]:
        var copy = full
        copy[i] = copy[i] xor delta
        try: discard decodeModule(copy)
        except DecodeError: discard

  test "function/code count mismatch":
    # function section declares one function but there is no code section
    expect DecodeError:
      discard decodeModule(hexBytes("0061736d01000000 0104 0160000 0 03020100".replace(" ", "")))

  test "sections out of order":
    # memory section (5) followed by type section (1)
    expect DecodeError:
      discard decodeModule(hexBytes("0061736d01000000 05030100 01 010100".replace(" ", "")))

  test "illegal opcode in body":
    expect DecodeError:
      discard decodeModule(hexBytes("0061736d010000000104016000000302010 00a05010300ff0b".replace(" ", "")))

  test "opcode table is consistent":
    for e in opTable:
      check isKnownOp(e.code)
      check opInfo(e.code).name == e.name
      var info: OpInfo
      check opByName(e.name, info) and info.code == e.code
    check opTable.len > 180
