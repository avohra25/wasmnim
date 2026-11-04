## Validation: the type-checking algorithm from the WebAssembly spec appendix,
## run over every function body. As a side effect it rewrites each body so the
## interpreter never has to search for anything at run time:
##
## * `br`, `br_if` and `br_table` targets become absolute instruction indices
##   together with the number of values to carry and the stack height to unwind
##   to (`BrTarget`; for `br`/`br_if` they are packed into `x`, `y`, `z`).
## * `if` stores the index to jump to when the condition is false in `z`, and
##   `else` stores the index just past the matching `end`.
## * `Body.maxHeight` records the deepest operand stack the body can reach.

import std/strutils
import opcodes, types, errors

type
  Patch = object
    idx: int      ## instruction index, or br_table index when `sub >= 0`
    sub: int

  Frame = object
    op: uint16
    params, results: seq[ValType]
    height: int           ## operand stack height below the block's parameters
    unreachable: bool
    startIdx: int
    elseIdx: int
    patches: seq[Patch]

const unknown = -1  ## the "any type" marker used on the polymorphic stack

proc vtOfLetter(c: char): ValType =
  case c
  of 'i': vtI32
  of 'l': vtI64
  of 'f': vtF32
  else: vtF64

proc invalid(msg: string) {.noreturn.} =
  raise newException(ValidationError, msg)

proc invalid(fnIdx, pc: int, msg: string) {.noreturn.} =
  raise newException(ValidationError, "function " & $fnIdx & ", instruction " & $pc & ": " & msg)

# ---- module level checks ---------------------------------------------------------

proc checkLimits(l: Limits, bound: uint32, what: string) =
  if l.min > bound: invalid(what & " minimum is too large")
  if l.hasMax:
    if l.max > bound: invalid(what & " maximum is too large")
    if l.min > l.max: invalid(what & " minimum exceeds its maximum")

proc constType(m: Module, e: ConstExpr): ValType =
  if e.isGlobal:
    var gt: GlobalType
    if not m.globalType(int(e.idx), gt): invalid("unknown global " & $e.idx & " in constant expression")
    if int(e.idx) >= m.importCount(ekGlobal):
      invalid("constant expressions may only read imported globals")
    if gt.mut: invalid("constant expression reads a mutable global")
    gt.vt
  else:
    e.vt

proc checkFuncBody(m: Module, fnIdx: int, body: var Body)

proc validate*(m: var Module) =
  ## Raises `ValidationError` when the module is not well typed. On success all
  ## function bodies are ready to execute.
  for i, imp in m.imports:
    case imp.kind
    of ekFunc:
      if int(imp.typeIdx) >= m.types.len: invalid("import " & $i & " has an unknown type")
    of ekTable: checkLimits(imp.table, 0xFFFF_FFFF'u32, "table")
    of ekMemory: checkLimits(imp.mem, maxPages, "memory")
    of ekGlobal: discard
  if m.numTables > 1: invalid("at most one table is allowed")
  if m.numMems > 1: invalid("at most one memory is allowed")
  for t in m.tables: checkLimits(t, 0xFFFF_FFFF'u32, "table")
  for mem in m.mems: checkLimits(mem, maxPages, "memory")
  if m.funcs.len != m.bodies.len: invalid("function and code section sizes differ")
  for i, t in m.funcs:
    if int(t) >= m.types.len: invalid("function " & $i & " has an unknown type")
  for i, g in m.globals:
    if constType(m, g.init) != g.gt.vt:
      invalid("global " & $i & " initialiser has the wrong type")
  var seen: seq[string]
  for e in m.exports:
    if e.name in seen: invalid("duplicate export name \"" & e.name & "\"")
    seen.add e.name
    let limit =
      case e.kind
      of ekFunc: m.numFuncs
      of ekTable: m.numTables
      of ekMemory: m.numMems
      of ekGlobal: m.numGlobals
    if int(e.idx) >= limit: invalid("export \"" & e.name & "\" refers to an unknown " & $e.kind)
  if m.hasStart:
    if int(m.start) >= m.numFuncs: invalid("unknown start function")
    let ft = m.types[m.funcTypeIdx(int(m.start))]
    if ft.params.len != 0 or ft.results.len != 0: invalid("start function must take and return nothing")
  for i, e in m.elems:
    if int(e.table) >= m.numTables: invalid("element segment " & $i & " refers to an unknown table")
    if constType(m, e.offset) != vtI32: invalid("element segment offset must be i32")
    for f in e.funcs:
      if int(f) >= m.numFuncs: invalid("element segment " & $i & " refers to an unknown function")
  for i, d in m.datas:
    if int(d.mem) >= m.numMems: invalid("data segment " & $i & " refers to an unknown memory")
    if constType(m, d.offset) != vtI32: invalid("data segment offset must be i32")
  let imported = m.importCount(ekFunc)
  for i in 0 ..< m.bodies.len:
    checkFuncBody(m, imported + i, m.bodies[i])

# ---- function bodies ---------------------------------------------------------------

proc checkFuncBody(m: Module, fnIdx: int, body: var Body) =
  if body.validated: return
  let ft = m.types[m.funcTypeIdx(fnIdx)]
  var locals = ft.params
  locals.add body.locals
  var
    vals: seq[int]
    frames: seq[Frame]
    maxH = 0
  let code = body.code.len

  proc fail(pc: int, msg: string) {.noreturn.} = invalid(fnIdx, pc, msg)

  proc push(t: int) =
    vals.add t
    if vals.len > maxH: maxH = vals.len

  proc popAny(pc: int): int =
    if vals.len == frames[^1].height:
      if frames[^1].unreachable: return unknown
      fail(pc, "operand stack underflow")
    result = vals.pop()

  proc pop(pc: int, want: int): int =
    let got = popAny(pc)
    if got != want and got != unknown and want != unknown:
      fail(pc, "type mismatch: expected " & $ValType(want) & ", found " & $ValType(got))
    if got == unknown: want else: got

  proc popVals(pc: int, ts: seq[ValType]) =
    for i in countdown(ts.len - 1, 0): discard pop(pc, ord(ts[i]))

  proc pushVals(ts: seq[ValType]) =
    for t in ts: push(ord(t))

  proc pushFrame(op: uint16, params, results: seq[ValType], idx: int) =
    frames.add Frame(op: op, params: params, results: results, height: vals.len,
                     startIdx: idx, elseIdx: -1)
    pushVals(params)

  proc setUnreachable() =
    vals.setLen(frames[^1].height)
    frames[^1].unreachable = true

  proc labelTypes(f: Frame): seq[ValType] =
    if f.op == opLoop: f.params else: f.results

  proc frameAt(pc: int, depth: uint32): int =
    if int(depth) >= frames.len: fail(pc, "unknown label " & $depth)
    frames.len - 1 - int(depth)

  proc blockSig(pc: int, ins: Instr): (seq[ValType], seq[ValType]) =
    case ins.y
    of 0: (@[], @[])
    of 1: (@[], @[ValType(ins.x)])
    else:
      if int(ins.x) >= m.types.len: fail(pc, "unknown block type")
      (m.types[int(ins.x)].params, m.types[int(ins.x)].results)

  proc addPatch(fr: int, p: Patch) = frames[fr].patches.add p

  proc requireMem(pc: int) =
    if m.numMems == 0: fail(pc, "no memory is defined")

  pushFrame(opBlock, @[], ft.results, -1)

  var pc = 0
  while pc < code:
    let ins = body.code[pc]
    let info = opInfo(ins.op)
    case ins.op
    of opUnreachable: setUnreachable()
    of opNop: discard
    of opBlock, opLoop:
      let (ps, rs) = blockSig(pc, ins)
      popVals(pc, ps)
      pushFrame(ins.op, ps, rs, pc)
    of opIf:
      let (ps, rs) = blockSig(pc, ins)
      discard pop(pc, ord(vtI32))
      popVals(pc, ps)
      pushFrame(opIf, ps, rs, pc)
    of opElse:
      if frames[^1].op != opIf: fail(pc, "else without matching if")
      popVals(pc, frames[^1].results)
      if vals.len != frames[^1].height: fail(pc, "values left on the stack at else")
      frames[^1].op = opElse
      frames[^1].elseIdx = pc
      frames[^1].unreachable = false
      pushVals(frames[^1].params)
      body.code[frames[^1].startIdx].z = uint32(pc + 1)
    of opEnd:
      let f = frames[^1]
      popVals(pc, f.results)
      if vals.len != f.height: fail(pc, "values left on the stack at end of block")
      if f.op == opIf and f.params != f.results:
        fail(pc, "if without else must leave its parameters as its results")
      let target = uint32(pc + 1)
      for p in f.patches:
        if p.sub >= 0: body.brTables[p.idx][p.sub].pc = target
        else: body.code[p.idx].x = uint64(target)
      if f.op == opIf: body.code[f.startIdx].z = target
      elif f.op == opElse: body.code[f.elseIdx].z = target
      frames.setLen(frames.len - 1)
      if frames.len == 0:
        if pc != code - 1: fail(pc, "instructions after the end of the function")
      else:
        pushVals(f.results)
    of opBr:
      let fi = frameAt(pc, uint32(ins.x))
      let ts = labelTypes(frames[fi])
      popVals(pc, ts)
      let h = uint32(frames[fi].height)
      if frames[fi].op == opLoop:
        body.code[pc].x = uint64(frames[fi].startIdx + 1)
      else:
        addPatch(fi, Patch(idx: pc, sub: -1))
      body.code[pc].y = uint32(ts.len)
      body.code[pc].z = h
      setUnreachable()
    of opBrIf:
      let fi = frameAt(pc, uint32(ins.x))
      discard pop(pc, ord(vtI32))
      let ts = labelTypes(frames[fi])
      popVals(pc, ts)
      pushVals(ts)
      if frames[fi].op == opLoop:
        body.code[pc].x = uint64(frames[fi].startIdx + 1)
      else:
        addPatch(fi, Patch(idx: pc, sub: -1))
      body.code[pc].y = uint32(ts.len)
      body.code[pc].z = uint32(frames[fi].height)
    of opBrTable:
      discard pop(pc, ord(vtI32))
      let tbl = int(ins.x)
      let defaultFrame = frameAt(pc, body.brTables[tbl][^1].pc)
      let arity = labelTypes(frames[defaultFrame]).len
      for i in 0 ..< body.brTables[tbl].len:
        let fi = frameAt(pc, body.brTables[tbl][i].pc)
        let ts = labelTypes(frames[fi])
        if ts.len != arity: fail(pc, "br_table targets have different arities")
        # Each target must accept the values on the stack; check without consuming.
        let saved = vals
        popVals(pc, ts)
        vals = saved
        body.brTables[tbl][i].arity = uint32(ts.len)
        body.brTables[tbl][i].height = uint32(frames[fi].height)
        if frames[fi].op == opLoop:
          body.brTables[tbl][i].pc = uint32(frames[fi].startIdx + 1)
        else:
          addPatch(fi, Patch(idx: tbl, sub: i))
      popVals(pc, labelTypes(frames[defaultFrame]))
      setUnreachable()
    of opReturn:
      popVals(pc, ft.results)
      setUnreachable()
    of opCall:
      if int(ins.x) >= m.numFuncs: fail(pc, "unknown function " & $ins.x)
      let callee = m.types[m.funcTypeIdx(int(ins.x))]
      popVals(pc, callee.params)
      pushVals(callee.results)
    of opCallIndirect:
      if m.numTables == 0: fail(pc, "no table is defined")
      if ins.y != 0: fail(pc, "call_indirect table index must be 0")
      if int(ins.x) >= m.types.len: fail(pc, "unknown type " & $ins.x)
      discard pop(pc, ord(vtI32))
      let callee = m.types[int(ins.x)]
      popVals(pc, callee.params)
      pushVals(callee.results)
    of opDrop: discard popAny(pc)
    of opSelect:
      discard pop(pc, ord(vtI32))
      let a = popAny(pc)
      let b = popAny(pc)
      if a != b and a != unknown and b != unknown:
        fail(pc, "select operands have different types")
      push(if a == unknown: b else: a)
    of opLocalGet, opLocalSet, opLocalTee:
      if int(ins.x) >= locals.len: fail(pc, "unknown local " & $ins.x)
      let t = ord(locals[int(ins.x)])
      if ins.op == opLocalGet: push(t)
      elif ins.op == opLocalSet: discard pop(pc, t)
      else:
        discard pop(pc, t)
        push(t)
    of opGlobalGet, opGlobalSet:
      var gt: GlobalType
      if not m.globalType(int(ins.x), gt): fail(pc, "unknown global " & $ins.x)
      if ins.op == opGlobalGet: push(ord(gt.vt))
      else:
        if not gt.mut: fail(pc, "global " & $ins.x & " is immutable")
        discard pop(pc, ord(gt.vt))
    of opMemorySize:
      requireMem(pc)
      push(ord(vtI32))
    of opMemoryGrow:
      requireMem(pc)
      discard pop(pc, ord(vtI32))
      push(ord(vtI32))
    else:
      # Everything else is described fully by its signature string.
      if info.imm == immMem:
        requireMem(pc)
        if (1 shl int(ins.y)) > info.width:
          fail(pc, "alignment must not be larger than natural")
      elif info.imm in {immMemCopy, immMemFill}:
        requireMem(pc)
      let colon = info.sig.find(':')
      for i in countdown(colon - 1, 0):
        discard pop(pc, ord(vtOfLetter(info.sig[i])))
      for i in colon + 1 ..< info.sig.len:
        push(ord(vtOfLetter(info.sig[i])))
    inc pc

  if frames.len != 0: invalid(fnIdx, code, "function body is missing its final end")
  body.maxHeight = maxH
  body.validated = true
