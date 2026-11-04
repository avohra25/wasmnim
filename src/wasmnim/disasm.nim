## Prints a decoded module as WebAssembly text. The output uses numeric
## indices and the flat instruction syntax, and `parseWat` reads it back to the
## same module, so `wasm2wat` followed by `wat2wasm` is lossless apart from
## custom sections such as the name section. Call it on a module as decoded or
## parsed: validation rewrites branch immediates into absolute targets.

import std/[strutils, bitops]
import types, opcodes

proc quoted(bytes: seq[byte]): string =
  result = "\""
  for b in bytes:
    let c = char(b)
    if c in {' ' .. '~'} and c notin {'"', '\\'}: result.add c
    else: result.add "\\" & toHex(int(b), 2).toLowerAscii
  result.add "\""

proc nanText(payload: uint64, neg: bool, canonical: uint64): string =
  result = (if neg: "-nan" else: "nan")
  if payload != canonical: result.add ":0x" & toHex(payload).toLowerAscii.strip(trailing = false, chars = {'0'})

proc f32Text*(bits: uint32): string =
  let neg = (bits shr 31) != 0
  let exp = (bits shr 23) and 0xFF
  let frac = bits and 0x7FFFFF
  if exp == 0xFF:
    if frac == 0: return (if neg: "-inf" else: "inf")
    return nanText(uint64(frac), neg, 0x400000)
  let v = cast[float32](bits)
  $v

proc f64Text*(bits: uint64): string =
  let neg = (bits shr 63) != 0
  let exp = (bits shr 52) and 0x7FF
  let frac = bits and 0xFFFFFFFFFFFFF'u64
  if exp == 0x7FF:
    if frac == 0: return (if neg: "-inf" else: "inf")
    return nanText(frac, neg, 0x8000000000000'u64)
  let v = cast[float64](bits)
  $v

proc blockTypeText(ins: Instr): string =
  case ins.y
  of 0: ""
  of 1: " (result " & $ValType(ins.x) & ")"
  else: " (type " & $ins.x & ")"

proc instrText*(ins: Instr, body: Body): string =
  let info = opInfo(ins.op)
  result = info.name
  case info.imm
  of immNone, immMemIdx, immMemCopy, immMemFill: discard
  of immBlock: result.add blockTypeText(ins)
  of immLabel, immFunc, immLocal, immGlobal: result.add " " & $ins.x
  of immBrTable:
    for t in body.brTables[int(ins.x)]: result.add " " & $t.pc
  of immCallIndirect:
    if ins.y != 0: result.add " " & $ins.y
    result.add " (type " & $ins.x & ")"
  of immMem:
    if ins.x != 0: result.add " offset=" & $ins.x
    # the natural alignment is implied; print anything else explicitly
    if ins.y != uint32(countTrailingZeroBits(info.width)): result.add " align=" & $(1'u64 shl ins.y)
  of immI32: result.add " " & $cast[int32](uint32(ins.x and 0xFFFFFFFF'u64))
  of immI64: result.add " " & $cast[int64](ins.x)
  of immF32: result.add " " & f32Text(uint32(ins.x and 0xFFFFFFFF'u64))
  of immF64: result.add " " & f64Text(ins.x)

proc constText(c: ConstExpr): string =
  if c.isGlobal: return "(global.get " & $c.idx & ")"
  case c.vt
  of vtI32: "(i32.const " & $cast[int32](uint32(c.bits and 0xFFFFFFFF'u64)) & ")"
  of vtI64: "(i64.const " & $cast[int64](c.bits) & ")"
  of vtF32: "(f32.const " & f32Text(uint32(c.bits and 0xFFFFFFFF'u64)) & ")"
  of vtF64: "(f64.const " & f64Text(c.bits) & ")"

proc limitsText(l: Limits): string =
  result = $l.min
  if l.hasMax: result.add " " & $l.max

proc globalTypeText(g: GlobalType): string =
  if g.mut: "(mut " & $g.vt & ")" else: $g.vt

proc sigText(ft: FuncType): string =
  for p in ft.params: result.add " (param " & $p & ")"
  for r in ft.results: result.add " (result " & $r & ")"

proc disassemble*(m: Module): string =
  ## Returns the whole module as text.
  var lines = @["(module"]
  for i, ft in m.types:
    lines.add "  (type (;" & $i & ";) (func" & sigText(ft) & "))"
  for imp in m.imports:
    var desc: string
    case imp.kind
    of ekFunc: desc = "(func (type " & $imp.typeIdx & "))"
    of ekTable: desc = "(table " & limitsText(imp.table) & " funcref)"
    of ekMemory: desc = "(memory " & limitsText(imp.mem) & ")"
    of ekGlobal: desc = "(global " & globalTypeText(imp.global) & ")"
    lines.add "  (import " & quoted(cast[seq[byte]](imp.module)) & " " &
              quoted(cast[seq[byte]](imp.name)) & " " & desc & ")"
  let funcBase = m.importCount(ekFunc)
  for i, tIdx in m.funcs:
    lines.add "  ;; function " & $(funcBase + i)
    lines.add "  (func (type " & $tIdx & ")"
    let body = m.bodies[i]
    if body.locals.len > 0:
      var s = "    (local"
      for l in body.locals: s.add " " & $l
      lines.add s & ")"
    var depth = 2
    for k, ins in body.code:
      if k == body.code.high: break           # the final `end` is the `)` of the func
      if ins.op == opEnd or ins.op == opElse: dec depth
      lines.add repeat("  ", depth) & instrText(ins, body)
      if ins.op in {opBlock, opLoop, opIf, opElse}: inc depth
    lines[^1].add ")"
  for t in m.tables: lines.add "  (table " & limitsText(t) & " funcref)"
  for mem in m.mems: lines.add "  (memory " & limitsText(mem) & ")"
  for g in m.globals:
    lines.add "  (global " & globalTypeText(g.gt) & " " & constText(g.init) & ")"
  for e in m.exports:
    lines.add "  (export " & quoted(cast[seq[byte]](e.name)) & " (" & $e.kind & " " & $e.idx & "))"
  if m.hasStart: lines.add "  (start " & $m.start & ")"
  for seg in m.elems:
    var s = "  (elem (table " & $seg.table & ") " & constText(seg.offset)
    for f in seg.funcs: s.add " " & $f
    lines.add s & ")"
  for seg in m.datas:
    lines.add "  (data (memory " & $seg.mem & ") " & constText(seg.offset) & " " & quoted(seg.bytes) & ")"
  lines.add ")"
  lines.join("\n") & "\n"
