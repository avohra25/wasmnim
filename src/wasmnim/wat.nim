## WebAssembly text format (WAT) parser. Supports both the flat and the folded
## instruction syntax, symbolic names for every index space, inline
## `(export ..)` / `(import ..)` abbreviations and inline memory/table data.

import std/[tables, strutils, math, parseutils, bitops]
import errors, types, opcodes

# ---- s-expressions ----------------------------------------------------------

type
  SKind = enum skAtom, skStr, skList
  Sexp = ref object
    kind: SKind
    text: string          ## atom text, or the decoded bytes of a string literal
    items: seq[Sexp]
    pos: int

proc fail(pos: int, msg: string) {.noreturn.} =
  raise newDecodeError(pos, msg)

proc isAtomChar(c: char): bool =
  c notin {' ', '\t', '\n', '\r', '(', ')', '"', ';'}

proc parseSexps(src: string): seq[Sexp] =
  ## Parses a whole file into a list of top-level expressions.
  var i = 0
  var stack: seq[Sexp]
  var top: seq[Sexp]
  template add(s: Sexp) =
    if stack.len == 0: top.add(s) else: stack[^1].items.add(s)
  while i < src.len:
    let c = src[i]
    case c
    of ' ', '\t', '\n', '\r': inc i
    of ';':
      if i + 1 < src.len and src[i + 1] == ';':
        while i < src.len and src[i] != '\n': inc i
      else: fail(i, "unexpected character ';'")
    of '(':
      if i + 1 < src.len and src[i + 1] == ';':
        var depth = 1
        let start = i
        i += 2
        while depth > 0:
          if i + 1 >= src.len: fail(start, "unclosed block comment")
          if src[i] == '(' and src[i + 1] == ';': inc depth; i += 2
          elif src[i] == ';' and src[i + 1] == ')': dec depth; i += 2
          else: inc i
      else:
        let s = Sexp(kind: skList, pos: i)
        stack.add(s)
        inc i
    of ')':
      if stack.len == 0: fail(i, "unexpected ')'")
      let s = stack.pop()
      add(s)
      inc i
    of '"':
      let start = i
      inc i
      var buf = ""
      while true:
        if i >= src.len: fail(start, "unclosed string")
        let d = src[i]
        if d == '"': inc i; break
        if d == '\\':
          inc i
          if i >= src.len: fail(start, "unclosed string")
          case src[i]
          of 'n': buf.add('\n'); inc i
          of 't': buf.add('\t'); inc i
          of 'r': buf.add('\r'); inc i
          of '\\': buf.add('\\'); inc i
          of '"': buf.add('"'); inc i
          of '\'': buf.add('\''); inc i
          of 'u':
            inc i
            if i >= src.len or src[i] != '{': fail(i, "malformed unicode escape")
            let close = src.find('}', i)
            if close < 0: fail(i, "malformed unicode escape")
            var cp: int
            try: cp = parseHexInt(src[i + 1 ..< close])
            except ValueError: fail(i, "malformed unicode escape")
            if cp > 0x10FFFF or cp in 0xD800 .. 0xDFFF: fail(i, "invalid unicode scalar value")
            # encode as UTF-8
            if cp < 0x80: buf.add(char(cp))
            elif cp < 0x800:
              buf.add(char(0xC0 or (cp shr 6))); buf.add(char(0x80 or (cp and 0x3F)))
            elif cp < 0x10000:
              buf.add(char(0xE0 or (cp shr 12))); buf.add(char(0x80 or ((cp shr 6) and 0x3F)))
              buf.add(char(0x80 or (cp and 0x3F)))
            else:
              buf.add(char(0xF0 or (cp shr 18))); buf.add(char(0x80 or ((cp shr 12) and 0x3F)))
              buf.add(char(0x80 or ((cp shr 6) and 0x3F))); buf.add(char(0x80 or (cp and 0x3F)))
            i = close + 1
          of '0'..'9', 'a'..'f', 'A'..'F':
            if i + 1 >= src.len or src[i + 1] notin HexDigits: fail(i, "malformed hex escape")
            buf.add(char(parseHexInt(src[i .. i + 1])))
            i += 2
          else: fail(i, "unknown escape sequence")
        elif d == '\n': fail(i, "newline in string")
        else: buf.add(d); inc i
      add(Sexp(kind: skStr, text: buf, pos: start))
    else:
      let start = i
      while i < src.len and isAtomChar(src[i]): inc i
      if i == start: fail(i, "unexpected character")
      add(Sexp(kind: skAtom, text: src[start ..< i], pos: start))
  if stack.len > 0: fail(stack[^1].pos, "unclosed '('")
  top

proc isAtom(s: Sexp, t: string): bool = s.kind == skAtom and s.text == t
proc head(s: Sexp): string =
  if s.kind == skList and s.items.len > 0 and s.items[0].kind == skAtom: s.items[0].text else: ""

# ---- literals ----------------------------------------------------------------

proc stripUnderscores(s: string, pos: int): string =
  for k, c in s:
    if c == '_':
      if k == 0 or k == s.len - 1 or s[k - 1] == '_': fail(pos, "malformed number " & s)
    else: result.add(c)

proc parseIntLit(text: string, bits: int, pos: int): uint64 =
  ## Parses a signed or unsigned integer literal that fits in `bits` bits
  ## (as either an unsigned or a two's-complement signed value).
  var s = stripUnderscores(text, pos)
  var neg = false
  if s.startsWith("+"): s = s[1 .. ^1]
  elif s.startsWith("-"): neg = true; s = s[1 .. ^1]
  if s.len == 0: fail(pos, "malformed number " & text)
  var mag: uint64
  var ok = true
  if s.startsWith("0x") or s.startsWith("0X"):
    let h = s[2 .. ^1]
    if h.len == 0 or h.len > 16 + 16 or not h.allCharsInSet(HexDigits): ok = false
    else:
      var acc: uint64
      for ch in h:
        if acc shr 60 != 0: ok = false
        acc = (acc shl 4) or uint64(parseHexInt($ch))
      mag = acc
  else:
    if s.len == 0 or not s.allCharsInSet(Digits): ok = false
    else:
      var acc: uint64
      for ch in s:
        let d = uint64(ord(ch) - ord('0'))
        if acc > (high(uint64) - d) div 10: ok = false; break
        acc = acc * 10 + d
      mag = acc
  if not ok: fail(pos, "malformed number " & text)
  let maxU = if bits == 64: high(uint64) else: (1'u64 shl bits) - 1
  if neg:
    if mag > (1'u64 shl (bits - 1)): fail(pos, "constant out of range: " & text)
    result = (0'u64 - mag)
    if bits < 64: result = result and maxU
  else:
    if mag > maxU: fail(pos, "constant out of range: " & text)
    result = mag

proc parseHexFloat(s: string, pos: int): float64 =
  # s has no sign and starts with 0x
  var i = 2
  var mant: uint64
  var digits = 0
  var exp2 = 0
  var seenDot = false
  var sticky = false
  while i < s.len and s[i] notin {'p', 'P'}:
    let c = s[i]
    if c == '.':
      if seenDot: fail(pos, "malformed number " & s)
      seenDot = true
    elif c in HexDigits:
      let d = uint64(parseHexInt($c))
      if mant shr 60 == 0:
        mant = (mant shl 4) or d
        if seenDot: exp2 -= 4
      else:
        if d != 0: sticky = true
        if not seenDot: exp2 += 4
      inc digits
    else: fail(pos, "malformed number " & s)
    inc i
  if digits == 0: fail(pos, "malformed number " & s)
  if i < s.len:
    inc i
    var e = 0
    try: e = parseInt(s[i .. ^1])
    except ValueError: fail(pos, "malformed number " & s)
    exp2 += e
  if sticky: mant = mant or 1
  result = float64(mant)
  var e = exp2
  while e > 0:
    let step = min(e, 1000)
    result = result * pow(2.0, float64(step))
    e -= step
  while e < 0:
    let step = min(-e, 1000)
    result = result / pow(2.0, float64(step))
    e += step

proc parseFloatLit(text: string, is32: bool, pos: int): uint64 =
  ## Returns the IEEE bit pattern of the literal.
  var s = stripUnderscores(text, pos)
  var neg = false
  if s.startsWith("+"): s = s[1 .. ^1]
  elif s.startsWith("-"): neg = true; s = s[1 .. ^1]
  let signBit32 = 0x8000_0000'u64
  let signBit64 = 0x8000_0000_0000_0000'u64
  if s == "inf":
    if is32: return 0x7F80_0000'u64 or (if neg: signBit32 else: 0'u64)
    else: return 0x7FF0_0000_0000_0000'u64 or (if neg: signBit64 else: 0'u64)
  if s == "nan" or s.startsWith("nan:0x"):
    var payload: uint64 = if is32: 0x40_0000'u64 else: 0x8_0000_0000_0000'u64
    if s != "nan":
      try: payload = uint64(parseHexInt(s[6 .. ^1]))
      except ValueError: fail(pos, "malformed number " & text)
      let lim = if is32: 0x80_0000'u64 else: 0x10_0000_0000_0000'u64
      if payload == 0 or payload >= lim: fail(pos, "invalid NaN payload")
    if is32: return 0x7F80_0000'u64 or payload or (if neg: signBit32 else: 0'u64)
    else: return 0x7FF0_0000_0000_0000'u64 or payload or (if neg: signBit64 else: 0'u64)
  var v: float64
  if s.startsWith("0x") or s.startsWith("0X"):
    v = parseHexFloat(s.toLowerAscii(), pos)
  else:
    if s.len == 0 or s[0] notin Digits and s[0] != '.': fail(pos, "malformed number " & text)
    var consumed = 0
    try: consumed = parseutils.parseFloat(s, v)
    except ValueError: consumed = 0
    if consumed != s.len: fail(pos, "malformed number " & text)
  if neg: v = -v
  if is32:
    let f = float32(v)
    result = uint64(cast[uint32](f))
  else:
    result = cast[uint64](v)

# ---- module builder -------------------------------------------------------------

type
  Names = Table[string, int]

  Builder = object
    m: Module
    typeNames, funcNames, tableNames, memNames, globalNames: Names
    # state for the function currently being parsed
    localNames: Names
    labels: seq[string]
    body: Body

proc lookup(names: Names, s: Sexp, count: int, what: string): uint32 =
  if s.kind != skAtom: fail(s.pos, "expected " & what & " index")
  if s.text.startsWith("$"):
    if s.text notin names: fail(s.pos, "unknown " & what & " " & s.text)
    return uint32(names[s.text])
  let v = parseIntLit(s.text, 32, s.pos)
  if int(v) >= count and count >= 0: discard  # range is checked by the validator
  uint32(v)

proc findOrAddType(b: var Builder, ft: FuncType): uint32 =
  for i, t in b.m.types:
    if t == ft: return uint32(i)
  b.m.types.add(ft)
  uint32(b.m.types.len - 1)

proc parseValType(s: Sexp): ValType =
  if s.kind == skAtom:
    case s.text
    of "i32": return vtI32
    of "i64": return vtI64
    of "f32": return vtF32
    of "f64": return vtF64
    else: discard
  fail(s.pos, "expected a value type")

proc parseTypeUse(b: var Builder, items: seq[Sexp], j: var int,
                  paramNames: var seq[string], hasInline: var bool): uint32 =
  ## Consumes `(type $t)? (param ..)* (result ..)*` starting at items[j].
  var explicitType = -1
  if j < items.len and items[j].head == "type":
    let it = items[j]
    if it.items.len != 2: fail(it.pos, "malformed type use")
    explicitType = int(lookup(b.typeNames, it.items[1], b.m.types.len, "type"))
    inc j
  var ft: FuncType
  hasInline = false
  while j < items.len and items[j].head == "param":
    hasInline = true
    let it = items[j]
    if it.items.len >= 2 and it.items[1].kind == skAtom and it.items[1].text.startsWith("$"):
      if it.items.len != 3: fail(it.pos, "malformed named param")
      ft.params.add(parseValType(it.items[2]))
      paramNames.add(it.items[1].text)
    else:
      for k in 1 ..< it.items.len:
        ft.params.add(parseValType(it.items[k]))
        paramNames.add("")
    inc j
  while j < items.len and items[j].head == "result":
    hasInline = true
    for k in 1 ..< items[j].items.len: ft.results.add(parseValType(items[j].items[k]))
    inc j
  if explicitType >= 0:
    if explicitType >= b.m.types.len: fail(items[0].pos, "unknown type")
    if hasInline and b.m.types[explicitType] != ft:
      fail(items[0].pos, "inline function type does not match the type use")
    if not hasInline:
      paramNames.setLen(0)
      for _ in b.m.types[explicitType].params: paramNames.add("")
    return uint32(explicitType)
  b.findOrAddType(ft)

# ---- instructions ------------------------------------------------------------------

proc resolveLabel(b: Builder, s: Sexp): uint32 =
  if s.kind != skAtom: fail(s.pos, "expected a label")
  if s.text.startsWith("$"):
    for d in 0 ..< b.labels.len:
      if b.labels[b.labels.len - 1 - d] == s.text: return uint32(d)
    fail(s.pos, "unknown label " & s.text)
  uint32(parseIntLit(s.text, 32, s.pos))

proc looksLikeIndex(s: Sexp): bool =
  s.kind == skAtom and s.text.len > 0 and (s.text[0] == '$' or s.text[0] in Digits)

proc parseBlockType(b: var Builder, items: seq[Sexp], j: var int, ins: var Instr) =
  var names: seq[string]
  var inline: bool
  let startJ = j
  let hadType = j < items.len and items[j].head == "type"
  let typesBefore = b.m.types.len
  let idx = b.parseTypeUse(items, j, names, inline)
  if j == startJ:
    ins.y = 0
    b.m.types.setLen(typesBefore)
    return
  let ft = b.m.types[int(idx)]
  # Empty and single-result block types are encoded inline, so the entry that
  # parseTypeUse may have just added to the type section is not needed.
  if not hadType and ft.params.len == 0 and ft.results.len == 0:
    ins.y = 0
    b.m.types.setLen(typesBefore)
  elif not hadType and ft.params.len == 0 and ft.results.len == 1:
    ins.y = 1
    ins.x = uint64(ord(ft.results[0]))
    b.m.types.setLen(typesBefore)
  else:
    ins.y = 2
    ins.x = uint64(idx)

proc parseImmediates(b: var Builder, info: OpInfo, items: seq[Sexp], j: var int, at: Sexp): Instr =
  ## Parses the immediates of a plain instruction. `j` is the index of the
  ## first potential immediate and is advanced past what was consumed.
  result.op = info.code
  template nextAtom(what: string): Sexp =
    if j >= items.len or items[j].kind != skAtom: fail(at.pos, "expected " & what & " for " & info.name)
    inc j
    items[j - 1]
  case info.imm
  of immNone, immMemIdx, immMemCopy, immMemFill: discard
  of immBlock: discard  # handled by the caller
  of immLabel: result.x = uint64(b.resolveLabel(nextAtom("a label")))
  of immBrTable:
    var targets: seq[BrTarget]
    while j < items.len and looksLikeIndex(items[j]):
      targets.add(BrTarget(pc: b.resolveLabel(items[j])))
      inc j
    if targets.len == 0: fail(at.pos, "br_table needs at least a default label")
    result.x = uint64(b.body.brTables.len)
    b.body.brTables.add(targets)
  of immFunc:
    result.x = uint64(lookup(b.funcNames, nextAtom("a function"), -1, "function"))
  of immLocal:
    result.x = uint64(lookup(b.localNames, nextAtom("a local"), -1, "local"))
  of immGlobal:
    result.x = uint64(lookup(b.globalNames, nextAtom("a global"), -1, "global"))
  of immCallIndirect:
    if j < items.len and looksLikeIndex(items[j]):
      result.y = lookup(b.tableNames, items[j], -1, "table")
      inc j
    var names: seq[string]
    var inline: bool
    result.x = uint64(b.parseTypeUse(items, j, names, inline))
  of immMem:
    var offset = 0'u64
    var alignExp = -1
    while j < items.len and items[j].kind == skAtom and
          (items[j].text.startsWith("offset=") or items[j].text.startsWith("align=")):
      let t = items[j].text
      if t.startsWith("offset="):
        offset = parseIntLit(t[7 .. ^1], 32, items[j].pos)
      else:
        let a = parseIntLit(t[6 .. ^1], 32, items[j].pos)
        if a == 0 or (a and (a - 1)) != 0: fail(items[j].pos, "alignment must be a power of two")
        alignExp = countTrailingZeroBits(a)
      inc j
    result.x = offset
    result.y = uint32(if alignExp >= 0: alignExp else: countTrailingZeroBits(info.width))
  of immI32: result.x = parseIntLit(nextAtom("a constant").text, 32, items[j - 1].pos)
  of immI64: result.x = parseIntLit(nextAtom("a constant").text, 64, items[j - 1].pos)
  of immF32: result.x = parseFloatLit(nextAtom("a constant").text, true, items[j - 1].pos)
  of immF64: result.x = parseFloatLit(nextAtom("a constant").text, false, items[j - 1].pos)

proc emit(b: var Builder, ins: Instr) = b.body.code.add(ins)

proc parseSeq(b: var Builder, items: seq[Sexp], start: int)

proc blockInstr(b: var Builder, opName: string, items: seq[Sexp], j: var int, label: var string): Instr =
  var info: OpInfo
  discard opByName(opName, info)
  result.op = info.code
  label = ""
  if j < items.len and items[j].kind == skAtom and items[j].text.startsWith("$"):
    label = items[j].text
    inc j
  b.parseBlockType(items, j, result)

proc parseFolded(b: var Builder, e: Sexp) =
  if e.items.len == 0: fail(e.pos, "empty expression")
  if e.items[0].kind != skAtom: fail(e.pos, "expected an instruction")
  let name = e.items[0].text
  case name
  of "block", "loop":
    var j = 1
    var label: string
    let ins = b.blockInstr(name, e.items, j, label)
    b.emit(ins)
    b.labels.add(label)
    b.parseSeq(e.items, j)
    b.labels.setLen(b.labels.len - 1)
    b.emit(Instr(op: opEnd))
  of "if":
    var j = 1
    var label: string
    let ins = b.blockInstr("if", e.items, j, label)
    # condition: every folded expression before `(then`
    while j < e.items.len and e.items[j].head notin ["then", "else"]:
      if e.items[j].kind != skList: fail(e.items[j].pos, "expected a folded expression")
      b.parseFolded(e.items[j])
      inc j
    b.emit(ins)
    b.labels.add(label)
    if j >= e.items.len or e.items[j].head != "then": fail(e.pos, "`if` needs a (then ...) clause")
    b.parseSeq(e.items[j].items, 1)
    inc j
    if j < e.items.len:
      if e.items[j].head != "else": fail(e.items[j].pos, "expected (else ...)")
      b.emit(Instr(op: opElse))
      b.parseSeq(e.items[j].items, 1)
      inc j
    if j != e.items.len: fail(e.pos, "unexpected content after if")
    b.labels.setLen(b.labels.len - 1)
    b.emit(Instr(op: opEnd))
  else:
    var info: OpInfo
    if not opByName(name, info): fail(e.pos, "unknown instruction " & name)
    var j = 1
    let ins = b.parseImmediates(info, e.items, j, e)
    while j < e.items.len:
      if e.items[j].kind != skList: fail(e.items[j].pos, "unexpected token in folded expression")
      b.parseFolded(e.items[j])
      inc j
    b.emit(ins)

proc parseSeq(b: var Builder, items: seq[Sexp], start: int) =
  var i = start
  while i < items.len:
    let it = items[i]
    if it.kind == skList:
      b.parseFolded(it)
      inc i
    elif it.kind == skAtom:
      let name = it.text
      case name
      of "block", "loop", "if":
        inc i
        var label: string
        let ins = b.blockInstr(name, items, i, label)
        b.emit(ins)
        b.labels.add(label)
      of "else":
        inc i
        b.emit(Instr(op: opElse))
        if i < items.len and items[i].kind == skAtom and items[i].text.startsWith("$"): inc i
      of "end":
        inc i
        if b.labels.len == 0: fail(it.pos, "`end` without a matching block")
        b.labels.setLen(b.labels.len - 1)
        b.emit(Instr(op: opEnd))
        if i < items.len and items[i].kind == skAtom and items[i].text.startsWith("$"): inc i
      else:
        var info: OpInfo
        if not opByName(name, info): fail(it.pos, "unknown instruction " & name)
        inc i
        let ins = b.parseImmediates(info, items, i, it)
        b.emit(ins)
    else:
      fail(it.pos, "unexpected string literal")

# ---- module fields ------------------------------------------------------------------

proc parseLimits(items: seq[Sexp], j: var int): Limits =
  if j >= items.len or items[j].kind != skAtom: fail(items[0].pos, "expected limits")
  result.min = uint32(parseIntLit(items[j].text, 32, items[j].pos))
  inc j
  if j < items.len and items[j].kind == skAtom and items[j].text[0] in Digits:
    result.hasMax = true
    result.max = uint32(parseIntLit(items[j].text, 32, items[j].pos))
    inc j

proc parseGlobalType(s: Sexp): GlobalType =
  if s.head == "mut":
    if s.items.len != 2: fail(s.pos, "malformed mut")
    GlobalType(vt: parseValType(s.items[1]), mut: true)
  else:
    GlobalType(vt: parseValType(s), mut: false)

proc parseConstExpr(b: var Builder, s: Sexp): ConstExpr =
  var e = s
  if e.head == "offset":
    if e.items.len != 2: fail(e.pos, "malformed offset expression")
    e = e.items[1]
  if e.kind != skList or e.items.len != 2: fail(s.pos, "constant expression expected")
  case e.head
  of "i32.const": ConstExpr(vt: vtI32, bits: parseIntLit(e.items[1].text, 32, e.items[1].pos))
  of "i64.const": ConstExpr(vt: vtI64, bits: parseIntLit(e.items[1].text, 64, e.items[1].pos))
  of "f32.const": ConstExpr(vt: vtF32, bits: parseFloatLit(e.items[1].text, true, e.items[1].pos))
  of "f64.const": ConstExpr(vt: vtF64, bits: parseFloatLit(e.items[1].text, false, e.items[1].pos))
  of "global.get":
    ConstExpr(isGlobal: true, idx: lookup(b.globalNames, e.items[1], -1, "global"))
  else: fail(s.pos, "constant expression expected")

type Space = enum spFunc, spTable, spMem, spGlobal

proc inlineImportOf(field: Sexp): Sexp =
  for it in field.items:
    if it.head == "import": return it

proc firstHeader(field: Sexp): int =
  ## Index of the first item after the keyword and optional $name.
  result = 1
  if result < field.items.len and field.items[result].kind == skAtom and
     field.items[result].text.startsWith("$"): inc result

proc nameOf(field: Sexp): string =
  let j = firstHeader(field)
  if j == 2: field.items[1].text else: ""

proc declare(names: var Names, name: string, idx: int, pos: int) =
  if name.len > 0:
    if name in names: fail(pos, "duplicate name " & name)
    names[name] = idx

proc addExports(b: var Builder, field: Sexp, kind: ExternKind, idx: int) =
  for it in field.items:
    if it.head == "export":
      if it.items.len != 2 or it.items[1].kind != skStr: fail(it.pos, "malformed inline export")
      b.m.exports.add(Export(name: it.items[1].text, kind: kind, idx: uint32(idx)))

proc parseWat*(src: string): Module =
  ## Parses a `(module ...)` in text format (or a bare list of fields).
  var top = parseSexps(src)
  var fields: seq[Sexp]
  if top.len == 1 and top[0].head == "module":
    fields = top[0].items
    var j = 1
    if j < fields.len and fields[j].kind == skAtom: inc j
    fields = fields[j .. ^1]
  else:
    fields = top
  var b = Builder()

  # pass 1: names. Imports come first in every index space.
  var counts: array[Space, int]
  var importCounts: array[Space, int]
  for f in fields:
    if f.kind != skList: fail(f.pos, "expected a module field")
    case f.head
    of "import":
      if f.items.len != 4 or f.items[3].kind != skList: fail(f.pos, "malformed import")
      let desc = f.items[3]
      let sp = case desc.head
        of "func": spFunc
        of "table": spTable
        of "memory": spMem
        of "global": spGlobal
        else: fail(desc.pos, "malformed import description")
      inc importCounts[sp]
    of "func", "table", "memory", "global":
      if f.inlineImportOf() != nil:
        let sp = case f.head
          of "func": spFunc
          of "table": spTable
          of "memory": spMem
          else: spGlobal
        inc importCounts[sp]
    else: discard
  var typeCount = 0
  var nextImport: array[Space, int]
  for f in fields:
    case f.head
    of "type":
      declare(b.typeNames, nameOf(f), typeCount, f.pos)
      inc typeCount
    of "import":
      let desc = f.items[3]
      let sp = case desc.head
        of "func": spFunc
        of "table": spTable
        of "memory": spMem
        else: spGlobal
      let nm = if desc.items.len > 1 and desc.items[1].kind == skAtom and desc.items[1].text.startsWith("$"): desc.items[1].text else: ""
      let tbl = case sp
        of spFunc: addr b.funcNames
        of spTable: addr b.tableNames
        of spMem: addr b.memNames
        of spGlobal: addr b.globalNames
      declare(tbl[], nm, nextImport[sp], desc.pos)
      inc nextImport[sp]
    of "func", "table", "memory", "global":
      let sp = case f.head
        of "func": spFunc
        of "table": spTable
        of "memory": spMem
        else: spGlobal
      let tbl = case sp
        of spFunc: addr b.funcNames
        of spTable: addr b.tableNames
        of spMem: addr b.memNames
        of spGlobal: addr b.globalNames
      if f.inlineImportOf() != nil:
        declare(tbl[], nameOf(f), nextImport[sp], f.pos)
        inc nextImport[sp]
      else:
        declare(tbl[], nameOf(f), importCounts[sp] + counts[sp], f.pos)
        inc counts[sp]
    else: discard

  # pass 2: build. Types first so explicit types get the lowest indices.
  for f in fields:
    if f.head == "type":
      let j = firstHeader(f)
      if j + 1 != f.items.len or f.items[j].head != "func": fail(f.pos, "malformed type definition")
      let fn = f.items[j]
      var ft: FuncType
      for it in fn.items[1 .. ^1]:
        case it.head
        of "param":
          if it.items.len >= 2 and it.items[1].kind == skAtom and it.items[1].text.startsWith("$"):
            ft.params.add(parseValType(it.items[2]))
          else:
            for k in 1 ..< it.items.len: ft.params.add(parseValType(it.items[k]))
        of "result":
          for k in 1 ..< it.items.len: ft.results.add(parseValType(it.items[k]))
        else: fail(it.pos, "malformed function type")
      b.m.types.add(ft)

  var pendingFuncs: seq[(Sexp, int, seq[string], uint32)]  # field, func index, param names, type
  var funcIdx = 0
  for f in fields:
    case f.head
    of "type": discard
    of "import":
      let desc = f.items[3]
      var im = Import(module: f.items[1].text, name: f.items[2].text)
      var j = 1
      if j < desc.items.len and desc.items[j].kind == skAtom and desc.items[j].text.startsWith("$"): inc j
      case desc.head
      of "func":
        var names: seq[string]
        var inl: bool
        im.kind = ekFunc
        im.typeIdx = b.parseTypeUse(desc.items, j, names, inl)
        inc funcIdx
      of "table":
        im.kind = ekTable
        im.table = parseLimits(desc.items, j)
      of "memory":
        im.kind = ekMemory
        im.mem = parseLimits(desc.items, j)
      else:
        im.kind = ekGlobal
        im.global = parseGlobalType(desc.items[j])
      b.m.imports.add(im)
    of "func":
      var j = firstHeader(f)
      let imp = f.inlineImportOf()
      var names: seq[string]
      var inl: bool
      # skip (export)/(import) headers
      while j < f.items.len and f.items[j].head in ["export", "import"]: inc j
      let ty = b.parseTypeUse(f.items, j, names, inl)
      if imp != nil:
        b.m.imports.add(Import(module: imp.items[1].text, name: imp.items[2].text, kind: ekFunc, typeIdx: ty))
        b.addExports(f, ekFunc, funcIdx)
      else:
        b.addExports(f, ekFunc, funcIdx)
        b.m.funcs.add(ty)
        # remember the rest of the field for pass 3
        var rest = Sexp(kind: skList, pos: f.pos, items: f.items[0 ..< 1])
        rest.items.add(f.items[j .. ^1])
        pendingFuncs.add((rest, funcIdx, names, ty))
      inc funcIdx
    of "table":
      var j = firstHeader(f)
      let imp = f.inlineImportOf()
      while j < f.items.len and f.items[j].head in ["export", "import"]: inc j
      let tIdx = b.m.numTables
      b.addExports(f, ekTable, tIdx)
      if j < f.items.len and f.items[j].kind == skAtom and f.items[j].text == "funcref":
        # (table funcref (elem $a $b))
        inc j
        if j >= f.items.len or f.items[j].head != "elem": fail(f.pos, "expected (elem ...)")
        var seg = ElemSegment(offset: ConstExpr(vt: vtI32, bits: 0))
        for k in 1 ..< f.items[j].items.len:
          seg.funcs.add(lookup(b.funcNames, f.items[j].items[k], -1, "function"))
        let n = uint32(seg.funcs.len)
        b.m.tables.add(Limits(min: n, hasMax: true, max: n))
        b.m.elems.add(seg)
      else:
        let lim = parseLimits(f.items, j)
        if j < f.items.len and f.items[j].isAtom("funcref"): inc j
        if imp != nil:
          b.m.imports.add(Import(module: imp.items[1].text, name: imp.items[2].text, kind: ekTable, table: lim))
        else: b.m.tables.add(lim)
    of "memory":
      var j = firstHeader(f)
      let imp = f.inlineImportOf()
      while j < f.items.len and f.items[j].head in ["export", "import"]: inc j
      b.addExports(f, ekMemory, b.m.numMems)
      if j < f.items.len and f.items[j].head == "data":
        var bytes: seq[byte]
        for k in 1 ..< f.items[j].items.len:
          for c in f.items[j].items[k].text: bytes.add(byte(c))
        let pages = uint32((bytes.len + pageSize - 1) div pageSize)
        b.m.mems.add(Limits(min: pages, hasMax: true, max: pages))
        b.m.datas.add(DataSegment(offset: ConstExpr(vt: vtI32, bits: 0), bytes: bytes))
      else:
        let lim = parseLimits(f.items, j)
        if imp != nil:
          b.m.imports.add(Import(module: imp.items[1].text, name: imp.items[2].text, kind: ekMemory, mem: lim))
        else: b.m.mems.add(lim)
    of "global":
      var j = firstHeader(f)
      let imp = f.inlineImportOf()
      while j < f.items.len and f.items[j].head in ["export", "import"]: inc j
      b.addExports(f, ekGlobal, b.m.numGlobals)
      if j >= f.items.len: fail(f.pos, "global type expected")
      let gt = parseGlobalType(f.items[j])
      inc j
      if imp != nil:
        b.m.imports.add(Import(module: imp.items[1].text, name: imp.items[2].text, kind: ekGlobal, global: gt))
      else:
        if j >= f.items.len: fail(f.pos, "global initialiser expected")
        var init: ConstExpr
        if f.items[j].kind == skList: init = b.parseConstExpr(f.items[j])
        elif j + 1 < f.items.len:
          init = b.parseConstExpr(Sexp(kind: skList, pos: f.pos, items: @[f.items[j], f.items[j + 1]]))
        else: fail(f.pos, "global initialiser expected")
        b.m.globals.add(Global(gt: gt, init: init))
    of "export":
      if f.items.len != 3 or f.items[1].kind != skStr or f.items[2].kind != skList or f.items[2].items.len != 2:
        fail(f.pos, "malformed export")
      let d = f.items[2]
      var e = Export(name: f.items[1].text)
      case d.head
      of "func": e.kind = ekFunc; e.idx = lookup(b.funcNames, d.items[1], -1, "function")
      of "table": e.kind = ekTable; e.idx = lookup(b.tableNames, d.items[1], -1, "table")
      of "memory": e.kind = ekMemory; e.idx = lookup(b.memNames, d.items[1], -1, "memory")
      of "global": e.kind = ekGlobal; e.idx = lookup(b.globalNames, d.items[1], -1, "global")
      else: fail(d.pos, "malformed export description")
      b.m.exports.add(e)
    of "start":
      if f.items.len != 2: fail(f.pos, "malformed start")
      b.m.hasStart = true
      b.m.start = lookup(b.funcNames, f.items[1], -1, "function")
    of "elem":
      var j = 1
      var seg: ElemSegment
      if j < f.items.len and f.items[j].kind == skAtom and f.items[j].text.startsWith("$"):
        seg.table = lookup(b.tableNames, f.items[j], -1, "table"); inc j
      elif j < f.items.len and f.items[j].head == "table":
        seg.table = lookup(b.tableNames, f.items[j].items[1], -1, "table"); inc j
      if j >= f.items.len: fail(f.pos, "element offset expected")
      seg.offset = b.parseConstExpr(f.items[j]); inc j
      if j < f.items.len and f.items[j].isAtom("func"): inc j
      while j < f.items.len:
        seg.funcs.add(lookup(b.funcNames, f.items[j], -1, "function")); inc j
      b.m.elems.add(seg)
    of "data":
      var j = 1
      var seg: DataSegment
      if j < f.items.len and f.items[j].head == "memory":
        seg.mem = lookup(b.memNames, f.items[j].items[1], -1, "memory"); inc j
      if j >= f.items.len: fail(f.pos, "data offset expected")
      seg.offset = b.parseConstExpr(f.items[j]); inc j
      while j < f.items.len:
        if f.items[j].kind != skStr: fail(f.items[j].pos, "data string expected")
        for c in f.items[j].text: seg.bytes.add(byte(c))
        inc j
      b.m.datas.add(seg)
    else: fail(f.pos, "unknown module field " & f.head)

  # pass 3: function bodies (all indices are known now)
  for (rest, idx, paramNames, ty) in pendingFuncs:
    b.localNames = initTable[string, int]()
    b.labels.setLen(0)
    b.body = Body()
    let ft = b.m.types[int(ty)]
    for i, n in paramNames:
      if i < ft.params.len: declare(b.localNames, n, i, rest.pos)
    var j = 1
    var next = ft.params.len
    while j < rest.items.len and (rest.items[j].head in ["local", "param", "result", "type"]):
      let it = rest.items[j]
      if it.head == "local":
        if it.items.len >= 2 and it.items[1].kind == skAtom and it.items[1].text.startsWith("$"):
          if it.items.len != 3: fail(it.pos, "malformed named local")
          declare(b.localNames, it.items[1].text, next, it.pos)
          b.body.locals.add(parseValType(it.items[2]))
          inc next
        else:
          for k in 1 ..< it.items.len:
            b.body.locals.add(parseValType(it.items[k])); inc next
      inc j
    b.parseSeq(rest.items, j)
    if b.labels.len != 0: fail(rest.pos, "unclosed block in function body")
    b.emit(Instr(op: opEnd))
    b.m.bodies.add(b.body)
  b.m
