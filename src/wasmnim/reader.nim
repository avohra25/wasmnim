## A bounds-checked cursor over a byte buffer with LEB128 decoding.

import errors

type
  Reader* = object
    data*: seq[byte]
    pos*: int
    limit*: int   ## exclusive end of the readable window

proc initReader*(data: seq[byte]): Reader =
  Reader(data: data, pos: 0, limit: data.len)

proc atEnd*(r: Reader): bool = r.pos >= r.limit
proc remaining*(r: Reader): int = r.limit - r.pos

proc fail*(r: Reader, msg: string) {.noreturn.} =
  raise newDecodeError(r.pos, msg)

proc readByte*(r: var Reader): byte =
  if r.pos >= r.limit: r.fail("unexpected end of input")
  result = r.data[r.pos]
  inc r.pos

proc peekByte*(r: Reader): byte =
  if r.pos >= r.limit: r.fail("unexpected end of input")
  r.data[r.pos]

proc readBytes*(r: var Reader, n: int): seq[byte] =
  if n < 0 or n > r.remaining: r.fail("unexpected end of input")
  result = r.data[r.pos ..< r.pos + n]
  r.pos += n

proc readU32*(r: var Reader): uint32 =
  ## Unsigned LEB128, at most 5 bytes, unused bits of the last byte must be zero.
  var shift = 0
  var acc = 0'u64
  for i in 0 ..< 5:
    let b = r.readByte()
    acc = acc or (uint64(b and 0x7F) shl shift)
    if (b and 0x80) == 0:
      if i == 4 and (b and 0x70) != 0: r.fail("integer too large")
      return uint32(acc)
    shift += 7
  r.fail("integer representation too long")

proc readSigned(r: var Reader, bits: int): int64 =
  ## Signed LEB128 of the given width (32 or 33 or 64).
  let maxBytes = (bits + 6) div 7
  var acc = 0'u64
  var shift = 0
  for i in 0 ..< maxBytes:
    let b = r.readByte()
    acc = acc or (uint64(b and 0x7F) shl shift)
    shift += 7
    if (b and 0x80) == 0:
      if i == maxBytes - 1:
        # the bits above `bits` in the last byte must be a sign extension
        let usedBits = bits - 7 * (maxBytes - 1)
        let signBit = (b shr (usedBits - 1)) and 1
        let top = int(b and 0x7F) shr usedBits
        let expected = if signBit == 1: (0x7F shr usedBits) else: 0
        if top != expected: r.fail("integer too large")
      if shift < 64 and (b and 0x40) != 0:
        acc = acc or ((not 0'u64) shl shift)
      return cast[int64](acc)
  r.fail("integer representation too long")

proc readS32*(r: var Reader): int32 = int32(r.readSigned(32))
proc readS33*(r: var Reader): int64 = r.readSigned(33)
proc readS64*(r: var Reader): int64 = r.readSigned(64)

proc readF32Bits*(r: var Reader): uint32 =
  let b = r.readBytes(4)
  for i in 0 ..< 4: result = result or (uint32(b[i]) shl (8 * i))

proc readF64Bits*(r: var Reader): uint64 =
  let b = r.readBytes(8)
  for i in 0 ..< 8: result = result or (uint64(b[i]) shl (8 * i))

proc readName*(r: var Reader): string =
  ## A length-prefixed UTF-8 string; invalid UTF-8 is rejected.
  let n = int(r.readU32())
  let b = r.readBytes(n)
  result = newString(n)
  for i in 0 ..< n: result[i] = char(b[i])
  # validate UTF-8
  var i = 0
  while i < n:
    let c = b[i]
    var extra = 0
    var minCp = 0'u32
    var cp = 0'u32
    if c < 0x80: extra = 0; cp = c
    elif c in 0xC2'u8 .. 0xDF'u8: extra = 1; cp = c and 0x1F; minCp = 0x80
    elif c in 0xE0'u8 .. 0xEF'u8: extra = 2; cp = c and 0x0F; minCp = 0x800
    elif c in 0xF0'u8 .. 0xF4'u8: extra = 3; cp = c and 0x07; minCp = 0x10000
    else: r.fail("malformed UTF-8 encoding")
    if i + extra > n - 1: r.fail("malformed UTF-8 encoding")
    for k in 1 .. extra:
      if (b[i + k] and 0xC0) != 0x80: r.fail("malformed UTF-8 encoding")
      cp = (cp shl 6) or (b[i + k] and 0x3F)
    if extra > 0 and (cp < minCp or cp > 0x10FFFF or cp in 0xD800'u32 .. 0xDFFF'u32):
      r.fail("malformed UTF-8 encoding")
    i += extra + 1

# ---- writing side (used by the text-format encoder and by tests) ----------

proc putU32*(o: var seq[byte], v: uint32) =
  var x = v
  while true:
    var b = byte(x and 0x7F)
    x = x shr 7
    if x != 0: o.add(b or 0x80) else:
      o.add(b); break

proc putS64*(o: var seq[byte], v: int64) =
  var x = v
  while true:
    let b = byte(x and 0x7F)
    x = x shr 7  # arithmetic shift on int64
    if (x == 0 and (b and 0x40) == 0) or (x == -1 and (b and 0x40) != 0):
      o.add(b); break
    o.add(b or 0x80)

proc putS32*(o: var seq[byte], v: int32) = putS64(o, int64(v))
