import std/unittest
import wasmnim, helpers

proc rd(hex: string): Reader = initReader(hexBytes(hex))

suite "LEB128":
  test "unsigned 32":
    var r = rd("00 7f 8001 e58e26 ffffffff0f")
    check r.readU32() == 0
    check r.readU32() == 127
    check r.readU32() == 128
    check r.readU32() == 624485
    check r.readU32() == 0xFFFFFFFF'u32
    check r.atEnd

  test "unsigned 32 rejects overlong and oversized encodings":
    expect DecodeError:
      var r = rd("8080808080 00")
      discard r.readU32()
    expect DecodeError:
      var r = rd("ffffffff1f")
      discard r.readU32()

  test "signed 32":
    var r = rd("00 7f 8001 807f c0bb78 ffffffff07 8080808078")
    check r.readS32() == 0
    check r.readS32() == -1
    check r.readS32() == 128
    check r.readS32() == -128
    check r.readS32() == -123456
    check r.readS32() == int32.high
    check r.readS32() == int32.low

  test "signed 32 rejects bad sign extension":
    expect DecodeError:
      var r = rd("ffffffff4f")
      discard r.readS32()

  test "signed 64":
    var r = rd("7f ffffffffffffffff7f 8080808080808080807f")
    check r.readS64() == -1
    check r.readS64() == -1
    check r.readS64() == int64.low

  test "signed 33 for block types":
    var r = rd("40 7f 05")
    check r.readS33() == -64
    check r.readS33() == -1
    check r.readS33() == 5

  test "writer and reader agree":
    for v in [0'i64, 1, -1, 63, 64, -64, -65, 8191, 8192, int64(int32.low), int64.high, int64.low]:
      var o: seq[byte]
      putS64(o, v)
      var r = initReader(o)
      check r.readS64() == v
      check r.atEnd
    for v in [0'u32, 1, 127, 128, 16384, 0xFFFFFFFF'u32]:
      var o: seq[byte]
      putU32(o, v)
      var r = initReader(o)
      check r.readU32() == v

  test "truncated input fails cleanly":
    expect DecodeError:
      var r = rd("80")
      discard r.readU32()
    expect DecodeError:
      var r = rd("0102")
      discard r.readBytes(5)

  test "names are validated as UTF-8":
    var r = rd("03 61 62 63")
    check r.readName() == "abc"
    var r2 = rd("02 c3 a9")
    check r2.readName() == "\xC3\xA9"
    expect DecodeError:
      var r3 = rd("01 80")
      discard r3.readName()
    expect DecodeError:
      var r4 = rd("02 c0 80")  # overlong NUL
      discard r4.readName()
    expect DecodeError:
      var r5 = rd("03 ed a0 80")  # surrogate
      discard r5.readName()
    expect DecodeError:
      var r6 = rd("02 e2 82")  # truncated sequence
      discard r6.readName()
