## Run-time objects: memories, tables, globals, functions and instances.
## Memories, tables and globals are reference objects so that several
## instances can share them through imports and exports.

import types, values

type
  Memory* = ref object
    data*: seq[byte]
    hasMax*: bool
    max*: uint32          ## in pages

  Table* = ref object
    elems*: seq[FuncInst]   ## nil marks an uninitialised slot
    hasMax*: bool
    max*: uint32

  GlobalInst* = ref object
    vt*: ValType
    mut*: bool
    bits*: uint64

  HostFunc* = proc(args: seq[Value]): seq[Value]

  FuncInst* = ref object
    ft*: FuncType
    host*: HostFunc          ## set for host functions
    inst*: Instance          ## defining instance for module functions
    bodyIdx*: int

  Instance* = ref object
    module*: Module
    funcs*: seq[FuncInst]
    tables*: seq[Table]
    mems*: seq[Memory]
    globals*: seq[GlobalInst]

  Extern* = object
    case kind*: ExternKind
    of ekFunc: fn*: FuncInst
    of ekTable: table*: Table
    of ekMemory: mem*: Memory
    of ekGlobal: global*: GlobalInst

const
  maxMemoryPages* = 4096'u32   ## engine limit: 256 MiB per memory

proc pages*(m: Memory): uint32 = uint32(m.data.len div pageSize)

proc newMemory*(minPages: uint32, maxPages = 0'u32, hasMax = false): Memory =
  Memory(data: newSeq[byte](int(minPages) * pageSize), hasMax: hasMax, max: maxPages)

proc grow*(m: Memory, delta: uint32): int64 =
  ## Returns the previous size in pages, or -1 when the memory cannot grow.
  let old = m.pages
  let limit = if m.hasMax: min(m.max, maxMemoryPages) else: maxMemoryPages
  if uint64(old) + uint64(delta) > uint64(limit): return -1
  m.data.setLen(int(old + delta) * pageSize)
  int64(old)

proc newTable*(minSize: uint32, maxSize = 0'u32, hasMax = false): Table =
  Table(elems: newSeq[FuncInst](int(minSize)), hasMax: hasMax, max: maxSize)

proc newGlobal*(v: Value, mut = false): GlobalInst =
  GlobalInst(vt: v.vt, mut: mut, bits: v.bits)

proc value*(g: GlobalInst): Value = Value(vt: g.vt, bits: g.bits)

proc hostFunc*(ft: FuncType, f: HostFunc): FuncInst = FuncInst(ft: ft, host: f)

proc externFunc*(f: FuncInst): Extern = Extern(kind: ekFunc, fn: f)
proc externMemory*(m: Memory): Extern = Extern(kind: ekMemory, mem: m)
proc externTable*(t: Table): Extern = Extern(kind: ekTable, table: t)
proc externGlobal*(g: GlobalInst): Extern = Extern(kind: ekGlobal, global: g)
