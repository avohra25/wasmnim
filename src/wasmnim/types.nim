## In-memory representation of a decoded WebAssembly module.

import std/strutils

type
  ValType* = enum
    vtI32 = "i32", vtI64 = "i64", vtF32 = "f32", vtF64 = "f64"

  FuncType* = object
    params*: seq[ValType]
    results*: seq[ValType]

  Limits* = object
    min*: uint32
    hasMax*: bool
    max*: uint32

  GlobalType* = object
    vt*: ValType
    mut*: bool

  ExternKind* = enum
    ekFunc = "func", ekTable = "table", ekMemory = "memory", ekGlobal = "global"

  Import* = object
    module*, name*: string
    kind*: ExternKind
    typeIdx*: uint32      ## ekFunc
    table*: Limits        ## ekTable (funcref elements)
    mem*: Limits          ## ekMemory
    global*: GlobalType   ## ekGlobal

  Export* = object
    name*: string
    kind*: ExternKind
    idx*: uint32

  ConstExpr* = object
    ## A constant initialiser: either a literal or a `global.get`.
    isGlobal*: bool
    vt*: ValType
    bits*: uint64
    idx*: uint32

  Global* = object
    gt*: GlobalType
    init*: ConstExpr

  ElemSegment* = object
    table*: uint32
    offset*: ConstExpr
    funcs*: seq[uint32]

  DataSegment* = object
    mem*: uint32
    offset*: ConstExpr
    bytes*: seq[byte]

  BrTarget* = object
    ## Before validation `pc` holds the relative label depth. After validation
    ## it is the absolute target pc, with the number of values to carry and the
    ## operand-stack height (above the locals) to unwind to.
    pc*, arity*, height*: uint32

  Instr* = object
    ## `x`, `y`, `z` hold immediates; their meaning depends on the opcode and on
    ## whether the body has been validated (validation resolves branch targets).
    op*: uint16
    x*: uint64
    y*: uint32
    z*: uint32

  Body* = object
    locals*: seq[ValType]       ## declared locals, not including parameters
    code*: seq[Instr]
    brTables*: seq[seq[BrTarget]]
    maxHeight*: int             ## deepest operand stack, filled in by validation
    validated*: bool

  CustomSection* = object
    name*: string
    data*: seq[byte]

  Module* = object
    types*: seq[FuncType]
    imports*: seq[Import]
    funcs*: seq[uint32]         ## type index of each defined function
    tables*: seq[Limits]
    mems*: seq[Limits]
    globals*: seq[Global]
    exports*: seq[Export]
    hasStart*: bool
    start*: uint32
    elems*: seq[ElemSegment]
    datas*: seq[DataSegment]
    bodies*: seq[Body]
    customs*: seq[CustomSection]

const
  pageSize* = 65536
  maxPages* = 65536'u32

proc valTypeFromByte*(b: byte, vt: var ValType): bool =
  case b
  of 0x7F: vt = vtI32
  of 0x7E: vt = vtI64
  of 0x7D: vt = vtF32
  of 0x7C: vt = vtF64
  else: return false
  true

proc toByte*(vt: ValType): byte =
  case vt
  of vtI32: 0x7F
  of vtI64: 0x7E
  of vtF32: 0x7D
  of vtF64: 0x7C

proc `$`*(ft: FuncType): string =
  "(" & ft.params.join(", ") & ") -> (" & ft.results.join(", ") & ")"

# ---- index spaces ----------------------------------------------------------

proc importCount*(m: Module, kind: ExternKind): int =
  for i in m.imports:
    if i.kind == kind: inc result

proc numFuncs*(m: Module): int = m.importCount(ekFunc) + m.funcs.len
proc numTables*(m: Module): int = m.importCount(ekTable) + m.tables.len
proc numMems*(m: Module): int = m.importCount(ekMemory) + m.mems.len
proc numGlobals*(m: Module): int = m.importCount(ekGlobal) + m.globals.len

proc funcTypeIdx*(m: Module, funcIdx: int): int =
  ## Type index of a function in the combined (imports first) index space, or -1.
  var n = funcIdx
  for i in m.imports:
    if i.kind == ekFunc:
      if n == 0: return int(i.typeIdx)
      dec n
  if n >= 0 and n < m.funcs.len: int(m.funcs[n]) else: -1

proc globalType*(m: Module, idx: int, gt: var GlobalType): bool =
  var n = idx
  for i in m.imports:
    if i.kind == ekGlobal:
      if n == 0:
        gt = i.global
        return true
      dec n
  if n >= 0 and n < m.globals.len:
    gt = m.globals[n].gt
    return true

proc findExport*(m: Module, name: string, kind: ExternKind, idx: var uint32): bool =
  for e in m.exports:
    if e.name == name and e.kind == kind:
      idx = e.idx
      return true
