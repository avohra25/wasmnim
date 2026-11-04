## Typed run-time values. Internally the interpreter keeps every value as the
## raw bits of a `uint64` (an i32 lives in the low half, an f32 as its IEEE
## bits); `Value` is the tagged form used at the API boundary.

import types

type
  Value* = object
    vt*: ValType
    bits*: uint64

proc i32Val*(x: int32): Value = Value(vt: vtI32, bits: uint64(cast[uint32](x)))
proc i64Val*(x: int64): Value = Value(vt: vtI64, bits: cast[uint64](x))
proc f32Val*(x: float32): Value = Value(vt: vtF32, bits: uint64(cast[uint32](x)))
proc f64Val*(x: float64): Value = Value(vt: vtF64, bits: cast[uint64](x))

proc zero*(vt: ValType): Value = Value(vt: vt, bits: 0)

proc asI32*(v: Value): int32 = cast[int32](uint32(v.bits and 0xFFFF_FFFF'u64))
proc asI64*(v: Value): int64 = cast[int64](v.bits)
proc asF32*(v: Value): float32 = cast[float32](uint32(v.bits and 0xFFFF_FFFF'u64))
proc asF64*(v: Value): float64 = cast[float64](v.bits)

proc `$`*(v: Value): string =
  case v.vt
  of vtI32: $v.asI32 & ":i32"
  of vtI64: $v.asI64 & ":i64"
  of vtF32: $v.asF32 & ":f32"
  of vtF64: $v.asF64 & ":f64"

proc `==`*(a, b: Value): bool = a.vt == b.vt and a.bits == b.bits
