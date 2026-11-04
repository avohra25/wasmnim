## Binary format decoder (WebAssembly 1.0 plus sign-extension, saturating
## truncation, multi-value blocks and `memory.copy`/`memory.fill`).
##
## The decoder checks the *structure* of a module. Type checking happens later
## in `validate`.

import errors, reader, opcodes, types

const
  magic = [0x00'u8, 0x61, 0x73, 0x6D]
  version = [0x01'u8, 0x00, 0x00, 0x00]
  maxLocals = 50_000

proc readValType(r: var Reader): ValType =
  let b = r.readByte()
  if not valTypeFromByte(b, result): r.fail("malformed value type 0x" & $int(b))

proc readLimits(r: var Reader, what: string): Limits =
  let flag = r.readByte()
  case flag
  of 0: result.min = r.readU32()
  of 1:
    result.min = r.readU32()
    result.hasMax = true
    result.max = r.readU32()
  else: r.fail("malformed limits flag in " & what)

proc readTableType(r: var Reader): Limits =
  if r.readByte() != 0x70: r.fail("only funcref tables are supported")
  r.readLimits("table")

proc readGlobalType(r: var Reader): GlobalType =
  result.vt = r.readValType()
  case r.readByte()
  of 0: result.mut = false
  of 1: result.mut = true
  else: r.fail("malformed mutability")

proc readConstExpr(r: var Reader): ConstExpr =
  let op = uint16(r.readByte())
  case op
  of opI32Const:
    result.vt = vtI32
    result.bits = uint64(uint32(r.readS32()))
  of opI64Const:
    result.vt = vtI64
    result.bits = cast[uint64](r.readS64())
  of opF32Const:
    result.vt = vtF32
    result.bits = uint64(r.readF32Bits())
  of opF64Const:
    result.vt = vtF64
    result.bits = r.readF64Bits()
  of opGlobalGet:
    result.isGlobal = true
    result.idx = r.readU32()
  else: r.fail("constant expression required")
  if r.readByte() != byte(opEnd): r.fail("constant expression must end with `end`")

proc readBlockType(r: var Reader, ins: var Instr) =
  # blocktype is an s33: -64 (0x40) = empty, -1..-4 = value type, >= 0 = type index
  let first = r.peekByte()
  if first == 0x40:
    discard r.readByte()
    ins.y = 0
    return
  var vt: ValType
  if valTypeFromByte(first, vt):
    discard r.readByte()
    ins.y = 1
    ins.x = uint64(ord(vt))
    return
  let v = r.readS33()
  if v < 0: r.fail("malformed block type")
  ins.y = 2
  ins.x = uint64(v)

proc readInstr(r: var Reader, body: var Body): Instr =
  var code = uint16(r.readByte())
  if code == 0xFC:
    code = opPrefixFC + uint16(r.readU32())
  if not isKnownOp(code): r.fail("illegal opcode " & opName(code))
  result.op = code
  case opInfo(code).imm
  of immNone: discard
  of immBlock: r.readBlockType(result)
  of immLabel, immFunc, immLocal, immGlobal: result.x = uint64(r.readU32())
  of immBrTable:
    let n = int(r.readU32())
    if n > r.remaining: r.fail("br_table too large")
    var targets = newSeq[BrTarget](n + 1)
    for i in 0 .. n: targets[i].pc = r.readU32()
    result.x = uint64(body.brTables.len)
    body.brTables.add(targets)
  of immCallIndirect:
    result.x = uint64(r.readU32())
    result.y = r.readU32()
  of immMem:
    result.y = r.readU32()        # alignment exponent
    result.x = uint64(r.readU32())  # offset
  of immMemIdx, immMemFill:
    if r.readByte() != 0: r.fail("zero byte expected")
  of immMemCopy:
    if r.readByte() != 0 or r.readByte() != 0: r.fail("zero byte expected")
  of immI32: result.x = uint64(uint32(r.readS32()))
  of immI64: result.x = cast[uint64](r.readS64())
  of immF32: result.x = uint64(r.readF32Bits())
  of immF64: result.x = r.readF64Bits()

proc readBody(r: var Reader): Body =
  let size = int(r.readU32())
  if size > r.remaining: r.fail("function body extends past the section")
  let endPos = r.pos + size
  let savedLimit = r.limit
  r.limit = endPos
  var total = 0
  for _ in 0 ..< int(r.readU32()):
    let n = int(r.readU32())
    total += n
    if total > maxLocals: r.fail("too many locals")
    let vt = r.readValType()
    for _ in 0 ..< n: result.locals.add(vt)
  var depth = 0
  while true:
    let ins = r.readInstr(result)
    result.code.add(ins)
    case ins.op
    of opBlock, opLoop, opIf: inc depth
    of opEnd:
      if depth == 0: break
      dec depth
    else: discard
  if r.pos != endPos: r.fail("function body has trailing bytes")
  r.limit = savedLimit

proc decodeModule*(data: seq[byte]): Module =
  var r = initReader(data)
  if r.remaining < 8: r.fail("unexpected end of input (no module header)")
  for i in 0 ..< 4:
    if r.readByte() != magic[i]: r.fail("magic header not detected")
  for i in 0 ..< 4:
    if r.readByte() != version[i]: r.fail("unknown binary version")

  var lastId = 0
  var codeCount = -1
  while not r.atEnd:
    let id = r.readByte()
    let size = int(r.readU32())
    if size > r.remaining: r.fail("section size exceeds module length")
    let endPos = r.pos + size
    let savedLimit = r.limit
    r.limit = endPos
    if id != 0:
      if int(id) <= lastId and not (id == 12 and lastId < 10):
        r.fail("unexpected content after last section or sections out of order")
      if id > 12: r.fail("malformed section id " & $int(id))
      lastId = int(id)
    case id
    of 0:
      var c: CustomSection
      c.name = r.readName()
      c.data = r.readBytes(r.remaining)
      result.customs.add(c)
    of 1:
      for _ in 0 ..< int(r.readU32()):
        if r.readByte() != 0x60: r.fail("malformed function type")
        var ft: FuncType
        for _ in 0 ..< int(r.readU32()): ft.params.add(r.readValType())
        for _ in 0 ..< int(r.readU32()): ft.results.add(r.readValType())
        result.types.add(ft)
    of 2:
      for _ in 0 ..< int(r.readU32()):
        var im: Import
        im.module = r.readName()
        im.name = r.readName()
        case r.readByte()
        of 0:
          im.kind = ekFunc
          im.typeIdx = r.readU32()
        of 1:
          im.kind = ekTable
          im.table = r.readTableType()
        of 2:
          im.kind = ekMemory
          im.mem = r.readLimits("memory")
        of 3:
          im.kind = ekGlobal
          im.global = r.readGlobalType()
        else: r.fail("malformed import kind")
        result.imports.add(im)
    of 3:
      for _ in 0 ..< int(r.readU32()): result.funcs.add(r.readU32())
    of 4:
      for _ in 0 ..< int(r.readU32()): result.tables.add(r.readTableType())
    of 5:
      for _ in 0 ..< int(r.readU32()): result.mems.add(r.readLimits("memory"))
    of 6:
      for _ in 0 ..< int(r.readU32()):
        var g: Global
        g.gt = r.readGlobalType()
        g.init = r.readConstExpr()
        result.globals.add(g)
    of 7:
      for _ in 0 ..< int(r.readU32()):
        var e: Export
        e.name = r.readName()
        case r.readByte()
        of 0: e.kind = ekFunc
        of 1: e.kind = ekTable
        of 2: e.kind = ekMemory
        of 3: e.kind = ekGlobal
        else: r.fail("malformed export kind")
        e.idx = r.readU32()
        result.exports.add(e)
    of 8:
      result.hasStart = true
      result.start = r.readU32()
    of 9:
      for _ in 0 ..< int(r.readU32()):
        var seg: ElemSegment
        if r.readU32() != 0: r.fail("only active element segments for table 0 are supported")
        seg.offset = r.readConstExpr()
        for _ in 0 ..< int(r.readU32()): seg.funcs.add(r.readU32())
        result.elems.add(seg)
    of 10:
      codeCount = int(r.readU32())
      for _ in 0 ..< codeCount: result.bodies.add(r.readBody())
    of 11:
      for _ in 0 ..< int(r.readU32()):
        var seg: DataSegment
        if r.readU32() != 0: r.fail("only active data segments for memory 0 are supported")
        seg.offset = r.readConstExpr()
        seg.bytes = r.readBytes(int(r.readU32()))
        result.datas.add(seg)
    of 12:
      discard r.readU32()  # data count: accepted and ignored
    else: r.fail("malformed section id")
    if r.pos != endPos: r.fail("section size mismatch")
    r.limit = savedLimit

  if result.funcs.len != result.bodies.len:
    raise newDecodeError(r.pos, "function and code section have inconsistent lengths")
