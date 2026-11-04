## Binary encoder: the inverse of `decode`. It works on modules that have not
## been through `validate` yet (validation rewrites branch immediates).

import reader, opcodes, types

proc putByte(o: var seq[byte], b: byte) = o.add(b)

proc putName(o: var seq[byte], s: string) =
  o.putU32(uint32(s.len))
  for c in s: o.add(byte(c))

proc putFixed(o: var seq[byte], v: uint64, n: int) =
  for i in 0 ..< n: o.add(byte((v shr (8 * i)) and 0xFF))

proc putLimits(o: var seq[byte], l: Limits) =
  if l.hasMax:
    o.add(1); o.putU32(l.min); o.putU32(l.max)
  else:
    o.add(0); o.putU32(l.min)

proc putConstExpr(o: var seq[byte], e: ConstExpr) =
  if e.isGlobal:
    o.add(byte(opGlobalGet)); o.putU32(e.idx)
  else:
    case e.vt
    of vtI32: o.add(byte(opI32Const)); o.putS32(cast[int32](uint32(e.bits and 0xFFFFFFFF'u64)))
    of vtI64: o.add(byte(opI64Const)); o.putS64(cast[int64](e.bits))
    of vtF32: o.add(byte(opF32Const)); o.putFixed(e.bits, 4)
    of vtF64: o.add(byte(opF64Const)); o.putFixed(e.bits, 8)
  o.add(byte(opEnd))

proc putInstr(o: var seq[byte], ins: Instr, body: Body) =
  if ins.op >= opPrefixFC:
    o.add(0xFC); o.putU32(uint32(ins.op - opPrefixFC))
  else:
    o.add(byte(ins.op))
  case opInfo(ins.op).imm
  of immNone: discard
  of immBlock:
    case ins.y
    of 0: o.add(0x40)
    of 1: o.add(ValType(ins.x).toByte)
    else: o.putS64(int64(ins.x))
  of immLabel, immFunc, immLocal, immGlobal: o.putU32(uint32(ins.x))
  of immBrTable:
    let t = body.brTables[int(ins.x)]
    o.putU32(uint32(t.len - 1))
    for e in t: o.putU32(e.pc)
  of immCallIndirect:
    o.putU32(uint32(ins.x)); o.putU32(ins.y)
  of immMem:
    o.putU32(ins.y); o.putU32(uint32(ins.x))
  of immMemIdx, immMemFill: o.add(0)
  of immMemCopy: o.add(0); o.add(0)
  of immI32: o.putS32(cast[int32](uint32(ins.x and 0xFFFFFFFF'u64)))
  of immI64: o.putS64(cast[int64](ins.x))
  of immF32: o.putFixed(ins.x, 4)
  of immF64: o.putFixed(ins.x, 8)

proc section(o: var seq[byte], id: byte, payload: seq[byte]) =
  o.add(id)
  o.putU32(uint32(payload.len))
  o.add(payload)

proc encodeModule*(m: Module): seq[byte] =
  result = @[0x00'u8, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]
  template vec(id: byte, items: untyped, body: untyped) =
    if items.len > 0:
      var p {.inject.}: seq[byte]
      p.putU32(uint32(items.len))
      for it {.inject.} in items:
        body
      result.section(id, p)

  vec(1, m.types):
    p.add(0x60)
    p.putU32(uint32(it.params.len))
    for t in it.params: p.add(t.toByte)
    p.putU32(uint32(it.results.len))
    for t in it.results: p.add(t.toByte)
  vec(2, m.imports):
    p.putName(it.module); p.putName(it.name)
    case it.kind
    of ekFunc: p.add(0); p.putU32(it.typeIdx)
    of ekTable: p.add(1); p.add(0x70); p.putLimits(it.table)
    of ekMemory: p.add(2); p.putLimits(it.mem)
    of ekGlobal: p.add(3); p.add(it.global.vt.toByte); p.add(if it.global.mut: 1 else: 0)
  vec(3, m.funcs): p.putU32(it)
  vec(4, m.tables): p.add(0x70); p.putLimits(it)
  vec(5, m.mems): p.putLimits(it)
  vec(6, m.globals):
    p.add(it.gt.vt.toByte); p.add(if it.gt.mut: 1 else: 0)
    p.putConstExpr(it.init)
  vec(7, m.exports):
    p.putName(it.name)
    p.add(byte(ord(it.kind)))
    p.putU32(it.idx)
  if m.hasStart:
    var p: seq[byte]
    p.putU32(m.start)
    result.section(8, p)
  vec(9, m.elems):
    p.putU32(0)
    p.putConstExpr(it.offset)
    p.putU32(uint32(it.funcs.len))
    for f in it.funcs: p.putU32(f)
  vec(10, m.bodies):
    var b: seq[byte]
    # run-length encode the locals
    var groups: seq[(uint32, ValType)]
    for t in it.locals:
      if groups.len > 0 and groups[^1][1] == t: inc groups[^1][0]
      else: groups.add((1'u32, t))
    b.putU32(uint32(groups.len))
    for g in groups:
      b.putU32(g[0]); b.add(g[1].toByte)
    for ins in it.code: b.putInstr(ins, it)
    p.putU32(uint32(b.len))
    p.add(b)
  vec(11, m.datas):
    p.putU32(0)
    p.putConstExpr(it.offset)
    p.putU32(uint32(it.bytes.len))
    p.add(it.bytes)
  for c in m.customs:
    var p: seq[byte]
    p.putName(c.name)
    p.add(c.data)
    result.section(0, p)
