## The interpreter. Values live on one shared `uint64` stack; every call gets a
## window of it holding its parameters, then its locals, then its operand stack.
## Because the validator already resolved every branch, the main loop is a plain
## `case` over the opcode with no label searching.

{.push overflowChecks: off, rangeChecks: off.}

import std/[math, bitops]
import types, errors, values, store

const
  # Each wasm call is one native `execFunc` frame. Unoptimised builds use far
  # bigger frames, so the limit is lower there to stay inside an 8 MB stack.
  maxCallDepth* = when defined(release) or defined(danger): 3000 else: 400
  maxStackSlots = 1 shl 22

type
  Machine = object
    stack: seq[uint64]
    depth: int
    fuel: int64          ## decremented by branches and calls; traps at zero

# ---- numeric helpers -------------------------------------------------------------

template lo32(x: uint64): uint32 = uint32(x and 0xFFFF_FFFF'u64)
template s32(x: uint32): int32 = cast[int32](x)
template s64(x: uint64): int64 = cast[int64](x)
template u64(x: int64): uint64 = cast[uint64](x)
template w32(x: uint32): uint64 = uint64(x)
template f32of(x: uint64): float32 = cast[float32](lo32(x))
template f64of(x: uint64): float64 = cast[float64](x)
template bitsOf(x: float32): uint64 = uint64(cast[uint32](x))
template bitsOf(x: float64): uint64 = cast[uint64](x)
template bit(b: bool): uint64 = (if b: 1'u64 else: 0'u64)

proc sar32(a: uint32, k: uint32): uint32 =
  let n = k and 31
  if (a and 0x8000_0000'u32) == 0: a shr n else: not ((not a) shr n)

proc sar64(a: uint64, k: uint64): uint64 =
  let n = k and 63
  if (a and 0x8000_0000_0000_0000'u64) == 0: a shr n else: not ((not a) shr n)

proc clz32(a: uint32): uint32 = (if a == 0: 32'u32 else: uint32(countLeadingZeroBits(a)))
proc ctz32(a: uint32): uint32 = (if a == 0: 32'u32 else: uint32(countTrailingZeroBits(a)))
proc clz64(a: uint64): uint64 = (if a == 0: 64'u64 else: uint64(countLeadingZeroBits(a)))
proc ctz64(a: uint64): uint64 = (if a == 0: 64'u64 else: uint64(countTrailingZeroBits(a)))

proc fmin[T: SomeFloat](a, b: T): T =
  if a != a or b != b: return T(NaN)
  if a == b: return (if signbit(a): a else: b)
  if a < b: a else: b

proc fmax[T: SomeFloat](a, b: T): T =
  if a != a or b != b: return T(NaN)
  if a == b: return (if signbit(a): b else: a)
  if a > b: a else: b

proc nearest64(x: float64): float64 =
  if x != x or abs(x) >= 4503599627370496.0: return x   # NaN, inf, or already integral
  let f = floor(x)
  let d = x - f
  var r = f
  if d > 0.5 or (d == 0.5 and f mod 2.0 != 0.0): r = f + 1.0
  if r == 0.0 and signbit(x): -0.0 else: r

proc trapIf(cond: bool, k: TrapKind) {.inline.} =
  if cond: raise newTrap(k)

# float -> integer conversions work on float64: every float32 converts exactly.
proc truncS32(x: float64): uint64 =
  trapIf(x != x, tkInvalidConversion)
  trapIf(not (x > -2147483649.0 and x < 2147483648.0), tkIntOverflow)
  uint64(cast[uint32](int32(x)))

proc truncU32(x: float64): uint64 =
  trapIf(x != x, tkInvalidConversion)
  trapIf(not (x > -1.0 and x < 4294967296.0), tkIntOverflow)
  uint64(uint32(x))

proc truncS64(x: float64): uint64 =
  trapIf(x != x, tkInvalidConversion)
  trapIf(not (x >= -9223372036854775808.0 and x < 9223372036854775808.0), tkIntOverflow)
  u64(int64(x))

proc truncU64(x: float64): uint64 =
  trapIf(x != x, tkInvalidConversion)
  trapIf(not (x > -1.0 and x < 18446744073709551616.0), tkIntOverflow)
  uint64(x)

proc satS32(x: float64): uint64 =
  if x != x: 0'u64
  elif x <= -2147483648.0: 0x8000_0000'u64
  elif x >= 2147483648.0: 0x7FFF_FFFF'u64
  else: uint64(cast[uint32](int32(x)))

proc satU32(x: float64): uint64 =
  if x != x or x <= 0.0: 0'u64
  elif x >= 4294967296.0: 0xFFFF_FFFF'u64
  else: uint64(uint32(x))

proc satS64(x: float64): uint64 =
  if x != x: 0'u64
  elif x <= -9223372036854775808.0: 0x8000_0000_0000_0000'u64
  elif x >= 9223372036854775808.0: 0x7FFF_FFFF_FFFF_FFFF'u64
  else: u64(int64(x))

proc satU64(x: float64): uint64 =
  if x != x or x <= 0.0: 0'u64
  elif x >= 18446744073709551616.0: 0xFFFF_FFFF_FFFF_FFFF'u64
  else: uint64(x)

# ---- memory access (little endian host) ----------------------------------------------

proc rd(d: seq[byte], p: int, width: int): uint64 {.inline.} =
  case width
  of 1: uint64(d[p])
  of 2:
    var v: uint16
    copyMem(addr v, unsafeAddr d[p], 2)
    uint64(v)
  of 4:
    var v: uint32
    copyMem(addr v, unsafeAddr d[p], 4)
    uint64(v)
  else:
    var v: uint64
    copyMem(addr v, unsafeAddr d[p], 8)
    v

proc wr(d: var seq[byte], p: int, width: int, x: uint64) {.inline.} =
  case width
  of 1: d[p] = byte(x and 0xFF)
  of 2:
    let v = uint16(x and 0xFFFF)
    copyMem(addr d[p], unsafeAddr v, 2)
  of 4:
    let v = lo32(x)
    copyMem(addr d[p], unsafeAddr v, 4)
  else:
    copyMem(addr d[p], unsafeAddr x, 8)

proc sx(x: uint64, width: int): int64 =
  case width
  of 1: int64(cast[int8](uint8(x and 0xFF)))
  of 2: int64(cast[int16](uint16(x and 0xFFFF)))
  else: int64(cast[int32](lo32(x)))

proc fillMem(p: pointer, n: int, v: byte) {.inline.} =
  zeroMem(p, 0)
  let b = cast[ptr UncheckedArray[byte]](p)
  for i in 0 ..< n: b[i] = v

# ---- the machine -------------------------------------------------------------------

proc ensureStack(m: var Machine, upTo: int) {.inline.} =
  if upTo > m.stack.len:
    if upTo > maxStackSlots: raise newTrap(tkCallStackExhausted)
    m.stack.setLen(min(max(upTo, m.stack.len * 2), maxStackSlots))

proc callHost(m: var Machine, fi: FuncInst, base: int) =
  let np = fi.ft.params.len
  var args = newSeq[Value](np)
  for i in 0 ..< np: args[i] = Value(vt: fi.ft.params[i], bits: m.stack[base + i])
  var res: seq[Value]
  try:
    res = fi.host(args)
  except WasmError:
    raise
  except CatchableError as e:
    raise newTrap(tkHost, e.msg)
  if res.len != fi.ft.results.len:
    raise newTrap(tkHost, "host function returned " & $res.len & " values, expected " & $fi.ft.results.len)
  m.ensureStack(base + res.len + 1)
  for i, r in res:
    if r.vt != fi.ft.results[i]:
      raise newTrap(tkHost, "host function returned a value of the wrong type")
    m.stack[base + i] = r.bits

proc execFunc(m: var Machine, fi: FuncInst, base: int) =
  ## Runs `fi` with its arguments at `m.stack[base ..]`; leaves its results at
  ## the same place.
  if fi.host != nil:
    m.callHost(fi, base)
    return
  if m.depth >= maxCallDepth: raise newTrap(tkCallStackExhausted)
  inc m.depth
  let inst = fi.inst
  let body = addr inst.module.bodies[fi.bodyIdx]
  let np = fi.ft.params.len
  let nl = np + body.locals.len
  let ob = base + nl                       # operand stack base
  m.ensureStack(ob + body.maxHeight + 2)
  for i in np ..< nl: m.stack[base + i] = 0
  let nres = fi.ft.results.len
  let mem = if inst.mems.len > 0: inst.mems[0] else: nil
  var sp = ob
  var pc = 0
  let ncode = body.code.len

  template st(i: int): untyped = m.stack[i]
  template top: untyped = m.stack[sp - 1]

  template un32(e: untyped) =
    let a {.inject.} = lo32(top)
    top = uint64(uint32(e))
  template bin32(e: untyped) =
    let b {.inject.} = lo32(st(sp - 1))
    let a {.inject.} = lo32(st(sp - 2))
    dec sp
    top = uint64(uint32(e))
  template cmp32(e: untyped) =
    let b {.inject.} = lo32(st(sp - 1))
    let a {.inject.} = lo32(st(sp - 2))
    dec sp
    top = bit(e)
  template un64(e: untyped) =
    let a {.inject.} = top
    top = uint64(e)
  template bin64(e: untyped) =
    let b {.inject.} = st(sp - 1)
    let a {.inject.} = st(sp - 2)
    dec sp
    top = uint64(e)
  template cmp64(e: untyped) =
    let b {.inject.} = st(sp - 1)
    let a {.inject.} = st(sp - 2)
    dec sp
    top = bit(e)
  template unF32(e: untyped) =
    let a {.inject.} = f32of(top)
    top = bitsOf(float32(e))
  template binF32(e: untyped) =
    let b {.inject.} = f32of(st(sp - 1))
    let a {.inject.} = f32of(st(sp - 2))
    dec sp
    top = bitsOf(float32(e))
  template cmpF32(e: untyped) =
    let b {.inject.} = f32of(st(sp - 1))
    let a {.inject.} = f32of(st(sp - 2))
    dec sp
    top = bit(e)
  template unF64(e: untyped) =
    let a {.inject.} = f64of(top)
    top = bitsOf(float64(e))
  template binF64(e: untyped) =
    let b {.inject.} = f64of(st(sp - 1))
    let a {.inject.} = f64of(st(sp - 2))
    dec sp
    top = bitsOf(float64(e))
  template cmpF64(e: untyped) =
    let b {.inject.} = f64of(st(sp - 1))
    let a {.inject.} = f64of(st(sp - 2))
    dec sp
    top = bit(e)
  # any-typed unary conversion: `a` is the raw popped bits
  template conv(e: untyped) =
    let a {.inject.} = top
    top = uint64(e)

  template effective(width: int): int =
    let ea = uint64(lo32(top)) + ins.x
    if ea + uint64(width) > uint64(mem.data.len): raise newTrap(tkOutOfBoundsMemory)
    int(ea)
  template load(width: int, e: untyped) =
    let p = effective(width)
    let raw {.inject.} = rd(mem.data, p, width)
    top = uint64(e)
  template store(width: int) =
    let v = st(sp - 1)
    dec sp
    let p = effective(width)
    dec sp
    wr(mem.data, p, width, v)

  template branch(tpc, arity, height: uint32) =
    dec m.fuel
    if m.fuel <= 0: raise newTrap(tkOutOfFuel)
    let dst = ob + int(height)
    let n = int(arity)
    if n > 0 and dst != sp - n:
      for i in 0 ..< n: st(dst + i) = st(sp - n + i)
    sp = dst + n
    pc = int(tpc)

  while pc < ncode:
    let ins = body.code[pc]
    inc pc
    case ins.op
    of 0x00: raise newTrap(tkUnreachable)
    of 0x01, 0x02, 0x03, 0x0B: discard      # nop, block, loop, end
    of 0x04:                                # if
      dec sp
      if lo32(st(sp)) == 0: pc = int(ins.z)
    of 0x05: pc = int(ins.z)                # else: the then-branch finished
    of 0x0C: branch(uint32(ins.x), ins.y, ins.z)
    of 0x0D:
      dec sp
      if lo32(st(sp)) != 0: branch(uint32(ins.x), ins.y, ins.z)
    of 0x0E:
      dec sp
      let tbl = addr body.brTables[int(ins.x)]
      let i = int(min(uint64(lo32(st(sp))), uint64(tbl[].len - 1)))
      let t = tbl[][i]
      branch(t.pc, t.arity, t.height)
    of 0x0F: break
    of 0x10:
      dec m.fuel
      if m.fuel <= 0: raise newTrap(tkOutOfFuel)
      let callee = inst.funcs[int(ins.x)]
      let at = sp - callee.ft.params.len
      m.execFunc(callee, at)
      sp = at + callee.ft.results.len
    of 0x11:
      dec m.fuel
      if m.fuel <= 0: raise newTrap(tkOutOfFuel)
      dec sp
      let idx = int(lo32(st(sp)))
      let tab = inst.tables[0]
      if idx >= tab.elems.len: raise newTrap(tkOutOfBoundsTable)
      let callee = tab.elems[idx]
      if callee == nil: raise newTrap(tkUninitializedElement, "element " & $idx)
      if callee.ft != inst.module.types[int(ins.x)]: raise newTrap(tkIndirectCallType)
      let at = sp - callee.ft.params.len
      m.execFunc(callee, at)
      sp = at + callee.ft.results.len
    of 0x1A: dec sp
    of 0x1B:
      let c = lo32(st(sp - 1))
      sp -= 2
      if c == 0: top = st(sp)
    of 0x20: st(sp) = st(base + int(ins.x)); inc sp
    of 0x21: dec sp; st(base + int(ins.x)) = st(sp)
    of 0x22: st(base + int(ins.x)) = top
    of 0x23: st(sp) = inst.globals[int(ins.x)].bits; inc sp
    of 0x24: dec sp; inst.globals[int(ins.x)].bits = st(sp)
    # loads
    of 0x28: load(4, raw)
    of 0x29: load(8, raw)
    of 0x2A: load(4, raw)
    of 0x2B: load(8, raw)
    of 0x2C: load(1, uint32(sx(raw, 1)))
    of 0x2D: load(1, raw)
    of 0x2E: load(2, uint32(sx(raw, 2)))
    of 0x2F: load(2, raw)
    of 0x30: load(1, u64(sx(raw, 1)))
    of 0x31: load(1, raw)
    of 0x32: load(2, u64(sx(raw, 2)))
    of 0x33: load(2, raw)
    of 0x34: load(4, u64(sx(raw, 4)))
    of 0x35: load(4, raw)
    # stores
    of 0x36, 0x38: store(4)
    of 0x37, 0x39: store(8)
    of 0x3A, 0x3C: store(1)
    of 0x3B, 0x3D: store(2)
    of 0x3E: store(4)
    of 0x3F: st(sp) = uint64(mem.pages); inc sp
    of 0x40:
      let r = mem.grow(lo32(top))
      top = uint64(uint32(cast[int32](r)))
    of 0x41, 0x42, 0x43, 0x44: st(sp) = ins.x; inc sp
    # i32 comparisons
    of 0x45: un32(bit(a == 0'u32))
    of 0x46: cmp32(a == b)
    of 0x47: cmp32(a != b)
    of 0x48: cmp32(s32(a) < s32(b))
    of 0x49: cmp32(a < b)
    of 0x4A: cmp32(s32(a) > s32(b))
    of 0x4B: cmp32(a > b)
    of 0x4C: cmp32(s32(a) <= s32(b))
    of 0x4D: cmp32(a <= b)
    of 0x4E: cmp32(s32(a) >= s32(b))
    of 0x4F: cmp32(a >= b)
    # i64 comparisons
    of 0x50: un64(bit(a == 0'u64))
    of 0x51: cmp64(a == b)
    of 0x52: cmp64(a != b)
    of 0x53: cmp64(s64(a) < s64(b))
    of 0x54: cmp64(a < b)
    of 0x55: cmp64(s64(a) > s64(b))
    of 0x56: cmp64(a > b)
    of 0x57: cmp64(s64(a) <= s64(b))
    of 0x58: cmp64(a <= b)
    of 0x59: cmp64(s64(a) >= s64(b))
    of 0x5A: cmp64(a >= b)
    # float comparisons
    of 0x5B: cmpF32(a == b)
    of 0x5C: cmpF32(a != b)
    of 0x5D: cmpF32(a < b)
    of 0x5E: cmpF32(a > b)
    of 0x5F: cmpF32(a <= b)
    of 0x60: cmpF32(a >= b)
    of 0x61: cmpF64(a == b)
    of 0x62: cmpF64(a != b)
    of 0x63: cmpF64(a < b)
    of 0x64: cmpF64(a > b)
    of 0x65: cmpF64(a <= b)
    of 0x66: cmpF64(a >= b)
    # i32 arithmetic
    of 0x67: un32(clz32(a))
    of 0x68: un32(ctz32(a))
    of 0x69: un32(countSetBits(a))
    of 0x6A: bin32(a + b)
    of 0x6B: bin32(a - b)
    of 0x6C: bin32(a * b)
    of 0x6D:
      bin32(block:
        trapIf(b == 0, tkIntDivByZero)
        trapIf(s32(a) == low(int32) and s32(b) == -1, tkIntOverflow)
        cast[uint32](s32(a) div s32(b)))
    of 0x6E:
      bin32(block:
        trapIf(b == 0, tkIntDivByZero)
        a div b)
    of 0x6F:
      bin32(block:
        trapIf(b == 0, tkIntDivByZero)
        if s32(b) == -1: 0'u32 else: cast[uint32](s32(a) mod s32(b)))
    of 0x70:
      bin32(block:
        trapIf(b == 0, tkIntDivByZero)
        a mod b)
    of 0x71: bin32(a and b)
    of 0x72: bin32(a or b)
    of 0x73: bin32(a xor b)
    of 0x74: bin32(a shl (b and 31))
    of 0x75: bin32(sar32(a, b))
    of 0x76: bin32(a shr (b and 31))
    of 0x77: bin32(rotateLeftBits(a, int(b and 31)))
    of 0x78: bin32(rotateRightBits(a, int(b and 31)))
    # i64 arithmetic
    of 0x79: un64(clz64(a))
    of 0x7A: un64(ctz64(a))
    of 0x7B: un64(countSetBits(a))
    of 0x7C: bin64(a + b)
    of 0x7D: bin64(a - b)
    of 0x7E: bin64(a * b)
    of 0x7F:
      bin64(block:
        trapIf(b == 0, tkIntDivByZero)
        trapIf(s64(a) == low(int64) and s64(b) == -1, tkIntOverflow)
        u64(s64(a) div s64(b)))
    of 0x80:
      bin64(block:
        trapIf(b == 0, tkIntDivByZero)
        a div b)
    of 0x81:
      bin64(block:
        trapIf(b == 0, tkIntDivByZero)
        if s64(b) == -1: 0'u64 else: u64(s64(a) mod s64(b)))
    of 0x82:
      bin64(block:
        trapIf(b == 0, tkIntDivByZero)
        a mod b)
    of 0x83: bin64(a and b)
    of 0x84: bin64(a or b)
    of 0x85: bin64(a xor b)
    of 0x86: bin64(a shl (b and 63))
    of 0x87: bin64(sar64(a, b))
    of 0x88: bin64(a shr (b and 63))
    of 0x89: bin64(rotateLeftBits(a, int(b and 63)))
    of 0x8A: bin64(rotateRightBits(a, int(b and 63)))
    # f32 arithmetic
    of 0x8B: top = top and 0x7FFF_FFFF'u64
    of 0x8C: top = top xor 0x8000_0000'u64
    of 0x8D: unF32(ceil(float64(a)))
    of 0x8E: unF32(floor(float64(a)))
    of 0x8F: unF32(trunc(float64(a)))
    of 0x90: unF32(nearest64(float64(a)))
    of 0x91: unF32(sqrt(float64(a)))
    of 0x92: binF32(a + b)
    of 0x93: binF32(a - b)
    of 0x94: binF32(a * b)
    of 0x95: binF32(a / b)
    of 0x96: binF32(fmin(a, b))
    of 0x97: binF32(fmax(a, b))
    of 0x98: binF32(copySign(a, b))
    # f64 arithmetic
    of 0x99: top = top and 0x7FFF_FFFF_FFFF_FFFF'u64
    of 0x9A: top = top xor 0x8000_0000_0000_0000'u64
    of 0x9B: unF64(ceil(a))
    of 0x9C: unF64(floor(a))
    of 0x9D: unF64(trunc(a))
    of 0x9E: unF64(nearest64(a))
    of 0x9F: unF64(sqrt(a))
    of 0xA0: binF64(a + b)
    of 0xA1: binF64(a - b)
    of 0xA2: binF64(a * b)
    of 0xA3: binF64(a / b)
    of 0xA4: binF64(fmin(a, b))
    of 0xA5: binF64(fmax(a, b))
    of 0xA6: binF64(copySign(a, b))
    # conversions
    of 0xA7: conv(a and 0xFFFF_FFFF'u64)
    of 0xA8: conv(truncS32(float64(f32of(a))))
    of 0xA9: conv(truncU32(float64(f32of(a))))
    of 0xAA: conv(truncS32(f64of(a)))
    of 0xAB: conv(truncU32(f64of(a)))
    of 0xAC: conv(u64(int64(s32(lo32(a)))))
    of 0xAD: conv(a and 0xFFFF_FFFF'u64)
    of 0xAE: conv(truncS64(float64(f32of(a))))
    of 0xAF: conv(truncU64(float64(f32of(a))))
    of 0xB0: conv(truncS64(f64of(a)))
    of 0xB1: conv(truncU64(f64of(a)))
    of 0xB2: conv(bitsOf(float32(s32(lo32(a)))))
    of 0xB3: conv(bitsOf(float32(lo32(a))))
    of 0xB4: conv(bitsOf(float32(s64(a))))
    of 0xB5: conv(bitsOf(float32(a)))
    of 0xB6: conv(bitsOf(float32(f64of(a))))
    of 0xB7: conv(bitsOf(float64(s32(lo32(a)))))
    of 0xB8: conv(bitsOf(float64(lo32(a))))
    of 0xB9: conv(bitsOf(float64(s64(a))))
    of 0xBA: conv(bitsOf(float64(a)))
    of 0xBB: conv(bitsOf(float64(f32of(a))))
    of 0xBC, 0xBD, 0xBE, 0xBF: discard       # reinterpret: the bits already are the value
    # sign extension
    of 0xC0: conv(uint64(cast[uint32](int32(cast[int8](uint8(a and 0xFF))))))
    of 0xC1: conv(uint64(cast[uint32](int32(cast[int16](uint16(a and 0xFFFF))))))
    of 0xC2: conv(u64(int64(cast[int8](uint8(a and 0xFF)))))
    of 0xC3: conv(u64(int64(cast[int16](uint16(a and 0xFFFF)))))
    of 0xC4: conv(u64(int64(cast[int32](lo32(a)))))
    # saturating truncation
    of 0xFC00: conv(satS32(float64(f32of(a))))
    of 0xFC01: conv(satU32(float64(f32of(a))))
    of 0xFC02: conv(satS32(f64of(a)))
    of 0xFC03: conv(satU32(f64of(a)))
    of 0xFC04: conv(satS64(float64(f32of(a))))
    of 0xFC05: conv(satU64(float64(f32of(a))))
    of 0xFC06: conv(satS64(f64of(a)))
    of 0xFC07: conv(satU64(f64of(a)))
    of 0xFC0A:                               # memory.copy dst src n
      let n = uint64(lo32(st(sp - 1)))
      let s = uint64(lo32(st(sp - 2)))
      let d = uint64(lo32(st(sp - 3)))
      sp -= 3
      let size = uint64(mem.data.len)
      if s + n > size or d + n > size: raise newTrap(tkOutOfBoundsMemory)
      if n > 0: moveMem(addr mem.data[int(d)], addr mem.data[int(s)], int(n))
    of 0xFC0B:                               # memory.fill dst value n
      let n = uint64(lo32(st(sp - 1)))
      let v = byte(st(sp - 2) and 0xFF)
      let d = uint64(lo32(st(sp - 3)))
      sp -= 3
      if d + n > uint64(mem.data.len): raise newTrap(tkOutOfBoundsMemory)
      if n > 0: fillMem(addr mem.data[int(d)], int(n), v)
    else:
      raise newException(WasmError, "internal error: opcode " & $ins.op & " is not implemented")

  # Move the results down to where the caller expects them.
  if sp - nres != base:
    for i in 0 ..< nres: st(base + i) = st(sp - nres + i)
  dec m.depth

proc invoke*(fn: FuncInst, args: openArray[Value], fuel: int64 = int64.high): seq[Value] =
  ## Calls `fn` and returns its results. Raises `Trap` when execution traps.
  ## `fuel` bounds the number of branches and calls the invocation may perform.
  if args.len != fn.ft.params.len:
    raise newException(WasmError, "expected " & $fn.ft.params.len & " arguments, got " & $args.len)
  var m = Machine(stack: newSeq[uint64](4096), fuel: fuel)
  for i, a in args:
    if a.vt != fn.ft.params[i]:
      raise newException(WasmError, "argument " & $i & " should be " & $fn.ft.params[i])
    m.stack[i] = a.bits
  m.ensureStack(args.len + fn.ft.results.len + 2)
  m.execFunc(fn, 0)
  for i, t in fn.ft.results:
    result.add Value(vt: t, bits: m.stack[i])

{.pop.}
