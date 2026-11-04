## Instantiation: resolve imports, allocate state, run initialisers and the
## start function.

import types, errors, values, store, validate, interp

type
  ImportBinding* = tuple[module, name: string, ext: Extern]
  Imports* = seq[ImportBinding]

proc define*(imps: var Imports, module, name: string, e: Extern) =
  imps.add (module: module, name: name, ext: e)

proc defineFunc*(imps: var Imports, module, name: string, ft: FuncType, f: HostFunc) =
  imps.define(module, name, externFunc(hostFunc(ft, f)))

proc funcType*(params: openArray[ValType], results: openArray[ValType] = []): FuncType =
  FuncType(params: @params, results: @results)

proc linkFail(imp: Import, why: string) {.noreturn.} =
  raise newException(LinkError, "import " & imp.module & "." & imp.name & ": " & why)

proc limitsFit(have: Limits, haveSize: uint32, want: Limits): bool =
  ## An actual memory/table (current size, optional max) satisfies a declared import.
  if haveSize < want.min: return false
  if want.hasMax:
    if not have.hasMax or have.max > want.max: return false
  true

proc evalConst(e: ConstExpr, globals: seq[GlobalInst]): uint64 =
  if e.isGlobal: globals[int(e.idx)].bits else: e.bits

proc instantiate*(module: Module, imports: Imports = @[]): Instance =
  ## Validates (when needed) and instantiates `module`. Raises `LinkError` for
  ## missing or mismatched imports and `Trap` when a segment or the start
  ## function traps.
  var m = module
  validate(m)
  result = Instance(module: m)
  let inst = result

  for imp in m.imports:
    var found = false
    var ext: Extern
    for b in imports:
      if b.module == imp.module and b.name == imp.name:
        ext = b.ext
        found = true
        break
    if not found: linkFail(imp, "not provided")
    if ext.kind != imp.kind: linkFail(imp, "expected a " & $imp.kind & ", got a " & $ext.kind)
    case imp.kind
    of ekFunc:
      if ext.fn.ft != m.types[int(imp.typeIdx)]:
        linkFail(imp, "function type mismatch: expected " & $m.types[int(imp.typeIdx)] &
                      ", got " & $ext.fn.ft)
      inst.funcs.add ext.fn
    of ekTable:
      let t = ext.table
      if not limitsFit(Limits(hasMax: t.hasMax, max: t.max), uint32(t.elems.len), imp.table):
        linkFail(imp, "table limits do not fit")
      inst.tables.add t
    of ekMemory:
      let mm = ext.mem
      if not limitsFit(Limits(hasMax: mm.hasMax, max: mm.max), mm.pages, imp.mem):
        linkFail(imp, "memory limits do not fit")
      inst.mems.add mm
    of ekGlobal:
      let g = ext.global
      if g.vt != imp.global.vt or g.mut != imp.global.mut:
        linkFail(imp, "global type mismatch")
      inst.globals.add g

  for i, ti in m.funcs:
    inst.funcs.add FuncInst(ft: m.types[int(ti)], inst: inst, bodyIdx: i)
  for l in m.tables: inst.tables.add newTable(l.min, l.max, l.hasMax)
  for l in m.mems:
    if l.min > maxMemoryPages:
      raise newException(LinkError, "memory of " & $l.min & " pages exceeds the engine limit")
    inst.mems.add newMemory(l.min, l.max, l.hasMax)
  for g in m.globals:
    inst.globals.add GlobalInst(vt: g.gt.vt, mut: g.gt.mut, bits: evalConst(g.init, inst.globals))

  # Segments are bounds-checked before anything is written, so a failed
  # instantiation leaves no partial initialisation behind.
  for e in m.elems:
    let off = uint64(uint32(evalConst(e.offset, inst.globals) and 0xFFFF_FFFF'u64))
    if off + uint64(e.funcs.len) > uint64(inst.tables[int(e.table)].elems.len):
      raise newTrap(tkOutOfBoundsTable, "element segment does not fit")
  for d in m.datas:
    let off = uint64(uint32(evalConst(d.offset, inst.globals) and 0xFFFF_FFFF'u64))
    if off + uint64(d.bytes.len) > uint64(inst.mems[int(d.mem)].data.len):
      raise newTrap(tkOutOfBoundsMemory, "data segment does not fit")
  for e in m.elems:
    let off = int(evalConst(e.offset, inst.globals) and 0xFFFF_FFFF'u64)
    for i, fidx in e.funcs: inst.tables[int(e.table)].elems[off + i] = inst.funcs[int(fidx)]
  for d in m.datas:
    let off = int(evalConst(d.offset, inst.globals) and 0xFFFF_FFFF'u64)
    for i, b in d.bytes: inst.mems[int(d.mem)].data[off + i] = b

  if m.hasStart:
    discard invoke(inst.funcs[int(m.start)], [])

proc exportOf*(inst: Instance, name: string): Extern =
  for e in inst.module.exports:
    if e.name == name:
      case e.kind
      of ekFunc: return externFunc(inst.funcs[int(e.idx)])
      of ekTable: return externTable(inst.tables[int(e.idx)])
      of ekMemory: return externMemory(inst.mems[int(e.idx)])
      of ekGlobal: return externGlobal(inst.globals[int(e.idx)])
  raise newException(WasmError, "no export named " & name)

proc hasExport*(inst: Instance, name: string): bool =
  for e in inst.module.exports:
    if e.name == name: return true

proc getFunc*(inst: Instance, name: string): FuncInst =
  let e = inst.exportOf(name)
  if e.kind != ekFunc: raise newException(WasmError, "export " & name & " is not a function")
  e.fn

proc call*(inst: Instance, name: string, args: varargs[Value]): seq[Value] =
  ## Convenience: invoke an exported function by name.
  invoke(inst.getFunc(name), args)

proc callWithFuel*(inst: Instance, name: string, fuel: int64, args: varargs[Value]): seq[Value] =
  ## Like `call`, but traps with `tkOutOfFuel` after `fuel` branches and calls.
  invoke(inst.getFunc(name), args, fuel)

proc memoryOf*(inst: Instance, name = "memory"): Memory =
  let e = inst.exportOf(name)
  if e.kind != ekMemory: raise newException(WasmError, "export " & name & " is not a memory")
  e.mem
