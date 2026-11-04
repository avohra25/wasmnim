import std/[unittest, os, strutils, sequtils, math]
import ../src/wasmnim
import helpers

const corpusDir = currentSourcePath().parentDir / "corpus"

proc corpus(name: string, imports: Imports = @[]): Instance =
  ## Instantiate a corpus program from the bytes wasmtime's assembler produced.
  instantiate(decodeModule(hexBytes(readFile(corpusDir / name & ".wasm.hex").strip())), imports)

proc wat(src: string, imports: Imports = @[]): Instance = instantiate(parseWat(src), imports)

proc i32r(i: Instance, name: string, args: varargs[Value]): int32 = i.call(name, args)[0].asI32
proc i64r(i: Instance, name: string, args: varargs[Value]): int64 = i.call(name, args)[0].asI64
proc f64r(i: Instance, name: string, args: varargs[Value]): float64 = i.call(name, args)[0].asF64

proc trapKind(i: Instance, name: string, args: varargs[Value]): TrapKind =
  try:
    discard i.call(name, args)
  except Trap as t:
    return t.kind
  raise newException(AssertionDefect, name & " did not trap")

template v(x: int): Value = i32Val(int32(x))
template v64(x: int64): Value = i64Val(x)

suite "exec: classic programs":
  test "fibonacci, recursive and iterative":
    let i = corpus("fib")
    check i.i32r("fib", v(20)) == 6765
    check i.i32r("fib", v(1)) == 1
    check i.i64r("fib_iter", v(90)) == 2880067194370816120'i64

  test "factorial, gcd and collatz":
    let i = corpus("factorial")
    check i.i64r("fac", v64(20)) == 2432902008176640000'i64
    check i.i64r("fac", v64(21)) == -4249290049419214848'i64   # wraps, as i64.mul does
    check i.i32r("gcd", v(1071), v(462)) == 21
    check i.i32r("collatz_steps", v64(27)) == 111

  test "sieve of Eratosthenes over linear memory":
    let i = corpus("sieve")
    check i.i32r("count_primes", v(100)) == 25
    check i.i32r("count_primes", v(10000)) == 1229

suite "exec: control flow":
  let c = corpus("control")
  test "br_table with a default":
    check c.i32r("classify", v(-5)) == -1
    check c.i32r("classify", v(0)) == 0
    check c.i32r("classify", v(77)) == 0        # 1 + (x >> 31) is 1 for every x >= 0
    let d = wat("""(module (func (export "pick") (param i32) (result i32)
      (block $a (block $b (block $c
        (br_table $a $b $c (local.get 0)))
        (return (i32.const 30)))
        (return (i32.const 20)))
      (i32.const 10)))""")
    check d.i32r("pick", v(0)) == 10
    check d.i32r("pick", v(1)) == 20
    check d.i32r("pick", v(2)) == 30
    check d.i32r("pick", v(-1)) == 30           # out-of-range selectors take the default
  test "br_table carrying a value through nested blocks":
    check c.i32r("select_br", v(0)) == 211
    check c.i32r("select_br", v(1)) == 210
    check c.i32r("select_br", v(2)) == 200
    check c.i32r("select_br", v(3)) == 100
    check c.i32r("select_br", v(99)) == 100
  test "loops, nested ifs, early return":
    check c.i32r("sum_to", v(100)) == 5050
    check c.i32r("nested_if", v(1), v(1)) == 3
    check c.i32r("nested_if", v(0), v(1)) == 1
    check c.i32r("flat_if", v(0)) == 22
    check c.i32r("early", v(-3)) == -1
    check c.i32r("early", v(3)) == 1
  test "multi-value calls and block parameters":
    check c.i32r("multi") == -2
    check c.i32r("block_params", v(10)) == 30
  test "select and code after an unconditional branch":
    check c.i32r("sel", v(1), v(2), v(1)) == 1
    check c.i32r("sel", v(1), v(2), v(0)) == 2
    check c.i32r("dead") == 5

suite "exec: numerics":
  let n = corpus("numeric")
  test "integer wrap-around, rotates and bit counts":
    check n.i32r("clz", v(1)) == 31
    check n.i32r("clz", v(0)) == 32
    check n.i32r("ctz", v(0)) == 32
    check n.i32r("ctz", v(8)) == 3
    check n.i64r("popcnt", v64(-1)) == 64
    check n.i64r("i64_mul", v64(0x7FFF_FFFF_FFFF_FFFF'i64), v64(2)) == -2
    check n.i64r("shr_s64", v64(-16), v64(66)) == -4          # shift count is taken mod 64
  test "signed and unsigned division":
    check n.i32r("div_s", v(-7), v(2)) == -3
    check n.i32r("rem_s", v(-7), v(2)) == -1
    check n.i32r("div_u", v(-1), v(2)) == 0x7FFF_FFFF
    check n.i32r("rem_s", v(low(int32)), v(-1)) == 0
  test "float arithmetic":
    check n.f64r("f64_ops", f64Val(4.0), f64Val(2.5)) == 12.0
    check n.i32r("lt", f64Val(1.0), f64Val(2.0)) == 1
    check n.i32r("lt", f64Val(NaN), f64Val(2.0)) == 0
    check n.f64r("nearest", f64Val(2.5)) == 2.0
    check n.f64r("nearest", f64Val(3.5)) == 4.0
    check n.f64r("nearest", f64Val(-0.4)).classify == fcNegZero
    check n.f64r("fmin", f64Val(0.0), f64Val(-0.0)).classify == fcNegZero
    check n.f64r("fmax", f64Val(-0.0), f64Val(0.0)).classify == fcZero
    check n.f64r("fmin", f64Val(1.0), f64Val(NaN)).classify == fcNan
    check n.f64r("copysign", f64Val(3.0), f64Val(-0.0)) == -3.0
  test "float constants":
    check n.f64r("consts") == 3.0 + 1000.0 - 0.5
    check n.call("f32_consts")[0].asF32 == 1000.5'f32
    check n.call("nan")[0].asF32.classify == fcNan
    check n.f64r("inf") == NegInf
    check n.call("nan_payload")[0].bits == 0x7FF4_0000_0000_0001'u64
    check n.i64r("int_consts") == -1001
    check n.i32r("u32_max") == -1
  test "conversions":
    check n.i32r("wrap", v64(0x1_2345_6789'i64)) == 0x2345_6789
    check n.i64r("extend_s", v(-2)) == -2
    check n.i32r("extend8", v(0x80)) == -128
    check n.call("convert_u", v(-1))[0].asF32 == 4294967296.0'f32
    check n.f64r("convert_u64", v64(-1)) == 18446744073709551616.0
    check n.call("demote", f64Val(1.5))[0].asF32 == 1.5'f32
    check n.f64r("promote", f32Val(0.25'f32)) == 0.25
    check n.i32r("reinterpret", f32Val(1.0'f32)) == 0x3F80_0000
    check n.i32r("trunc_s", f64Val(-3.99)) == -3
  test "saturating truncation never traps":
    check n.i32r("trunc_sat_s", f64Val(1e30)) == high(int32)
    check n.i32r("trunc_sat_s", f64Val(-1e30)) == low(int32)
    check n.i32r("trunc_sat_s", f64Val(NaN)) == 0
    check n.i64r("trunc_sat_u64", f32Val(-5.0'f32)) == 0
    check n.i64r("trunc_sat_u64", f32Val(1e30'f32)) == -1
  test "plain truncation traps outside range":
    check n.trapKind("trunc_s", f64Val(3e9)) == tkIntOverflow
    check n.trapKind("trunc_s", f64Val(NaN)) == tkInvalidConversion
    check n.trapKind("div_s", v(1), v(0)) == tkIntDivByZero
    check n.trapKind("div_s", v(low(int32)), v(-1)) == tkIntOverflow

suite "exec: memory":
  test "data segments, loads, sign extension and offsets":
    let m = corpus("memory")
    check m.i32r("load8", v(16)) == int32('h')
    check m.i32r("load8", v(64 + 4)) == 255
    check m.i32r("load8s", v(64 + 4)) == -1
    check m.i32r("load_off", v(0)) == 0x6C6C6568'i32   # bytes "hell" read from address 16
  test "stores are little endian":
    let m = corpus("memory")
    discard m.call("store32", v(100), v(0x0A0B0C0D))
    check m.i32r("load8", v(100)) == 0x0D
    check m.i32r("load8", v(103)) == 0x0A
    discard m.call("store64", v(200), v64(0x0102030405060708'i64))
    check m.i64r("load64", v(200)) == 0x0102030405060708'i64
    discard m.call("storef32", v(300), f32Val(1.0'f32))
    check m.i32r("load8", v(303)) == 0x3F
  test "memory.grow, size, fill and copy":
    let m = corpus("memory")
    check m.i32r("size") == 1
    check m.i32r("grow", v(2)) == 1
    check m.i32r("size") == 3
    check m.i32r("grow", v(2)) == -1          # the declared maximum is 4
    check m.i32r("load8", v(3 * 65536 - 1)) == 0
    discard m.call("fill", v(1000), v(7), v(10))
    check m.i32r("sum", v(1000), v(10)) == 70
    discard m.call("copy", v(2000), v(1000), v(10))
    check m.i32r("sum", v(2000), v(10)) == 70
    # overlapping copy behaves as memmove
    discard m.call("store32", v(4000), v(0x04030201))
    discard m.call("copy", v(4001), v(4000), v(3))
    check m.i32r("load8", v(4001)) == 1
    check m.i32r("load8", v(4003)) == 3
  test "out-of-bounds accesses trap, including via the offset":
    let t = corpus("traps")
    check t.trapKind("oob_load", v(65536 - 3)) == tkOutOfBoundsMemory
    check t.trapKind("oob_load", v(-1)) == tkOutOfBoundsMemory
    check t.trapKind("oob_store", v(8)) == tkOutOfBoundsMemory
    check t.i32r("oob_load", v(65536 - 4)) == 0
  test "host code sees the same memory":
    let m = corpus("memory")
    let mem = m.memoryOf("mem")
    check mem.pages == 1
    check cast[char](mem.data[16]) == 'h'
  test "string escapes in data segments":
    let s = corpus("strings")
    let d = s.memoryOf().data
    check d[0 ..< 5].mapIt(char(it)).join == "plain"
    check d[5 ..< 18].mapIt(char(it)).join == " and \"quoted\""
    check d[32 .. 34] == @[byte 0x48, 0x49, 0xE2]

suite "exec: tables and globals":
  test "call_indirect dispatches through the table":
    let t = corpus("table")
    check t.i32r("apply", v(0), v(6), v(3)) == 9
    check t.i32r("apply", v(1), v(6), v(3)) == 3
    check t.i32r("apply", v(2), v(6), v(3)) == 18
    check t.i32r("apply1", v(3), v(5)) == -5
  test "call_indirect traps for missing, mistyped and out-of-range entries":
    let t = corpus("table")
    check t.trapKind("apply", v(4), v(1), v(1)) == tkUninitializedElement
    check t.trapKind("apply", v(9), v(1), v(1)) == tkOutOfBoundsTable
    check t.trapKind("apply", v(3), v(1), v(1)) == tkIndirectCallType
  test "mutable globals keep state across calls":
    let g = corpus("globals")
    check g.i32r("next") == 1
    check g.i32r("next") == 2
    check g.exportOf("counter").global.value.asI32 == 2
    discard g.call("reset")
    check g.i32r("next") == 1
    check g.i64r("big") == low(int64)
    check g.f64r("pi") == 3.14159265358979
    check g.exportOf("limit").global.value.asI32 == 100

suite "exec: traps and limits":
  let t = corpus("traps")
  test "each trap reports its kind":
    check t.trapKind("unreachable") == tkUnreachable
    check t.trapKind("div0", v(0)) == tkIntDivByZero
    check t.trapKind("overflow") == tkIntOverflow
    check t.i32r("rem_min") == 0
    check t.trapKind("bad_conv", f32Val(1e20'f32)) == tkIntOverflow
    check t.trapKind("call_empty") == tkUninitializedElement
  test "runaway recursion exhausts the call stack instead of crashing":
    check t.trapKind("forever") == tkCallStackExhausted
  test "fuel stops an infinite loop":
    let i = wat("(module (func (export \"spin\") (loop $l (br $l))))")
    try:
      discard i.callWithFuel("spin", 10_000)
      fail()
    except Trap as e:
      check e.kind == tkOutOfFuel
  test "a trap does not corrupt the instance for later calls":
    check t.trapKind("div0", v(0)) == tkIntDivByZero
    check t.i32r("div0", v(1)) == 1

suite "exec: host imports and linking":
  proc env(log: var seq[int32]): Imports =
    var imps: Imports
    var logp = addr log
    imps.defineFunc("env", "log", funcType([vtI32]), proc(a: seq[Value]): seq[Value] =
      logp[].add a[0].asI32
      @[])
    imps.defineFunc("env", "now", funcType([], [vtI64]), proc(a: seq[Value]): seq[Value] =
      @[i64Val(1234567890123'i64)])
    imps.defineFunc("env", "helper", funcType([vtI32, vtI32], [vtI32]),
      proc(a: seq[Value]): seq[Value] = @[i32Val(a[0].asI32 * 10 + a[1].asI32)])
    imps.define("env", "mem", externMemory(newMemory(1, 2, true)))
    imps.define("env", "base", externGlobal(newGlobal(i32Val(7))))
    imps

  test "imported functions, memory and globals":
    var log: seq[int32]
    let i = corpus("imports", env(log))
    check i.i32r("run", v(4)) == 47
    check log == @[4'i32]
    check i.i64r("stamp") == 1234567890123'i64

  test "missing and mismatched imports are link errors":
    expect LinkError: discard corpus("imports")
    var log: seq[int32]
    var bad = env(log)
    bad[0] = (module: "env", name: "log", ext: externFunc(hostFunc(funcType([vtI64]),
      proc(a: seq[Value]): seq[Value] = @[])))
    expect LinkError: discard corpus("imports", bad)
    var smallMem = env(log)
    smallMem[3] = (module: "env", name: "mem", ext: externMemory(newMemory(1, 9, true)))
    expect LinkError: discard corpus("imports", smallMem)

  test "a host exception becomes a trap":
    var imps: Imports
    imps.defineFunc("h", "boom", funcType([]), proc(a: seq[Value]): seq[Value] =
      raise newException(ValueError, "kaput"))
    let i = wat("""(module (import "h" "boom" (func $b)) (func (export "go") (call $b)))""", imps)
    check i.trapKind("go") == tkHost

  test "start functions run during instantiation":
    let i = wat("""(module (global $g (mut i32) (i32.const 0))
      (func $init (global.set $g (i32.const 42)))
      (start $init)
      (func (export "get") (result i32) (global.get $g)))""")
    check i.i32r("get") == 42

  test "segments that do not fit abort instantiation":
    expect Trap: discard wat("""(module (memory 1) (data (i32.const 65535) "ab"))""")
    expect Trap: discard wat("""(module (table 1 funcref) (func $f) (elem (i32.const 1) $f))""")

  test "wrong argument counts and types are rejected before running":
    let i = corpus("fib")
    expect WasmError: discard i.call("fib")
    expect WasmError: discard i.call("fib", f64Val(1.0))
