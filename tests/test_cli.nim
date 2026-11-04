import std/[unittest, os, strutils]
import ../src/wasmnim
import helpers

const corpusDir = currentSourcePath().parentDir / "corpus"
let tmp = getTempDir() / "wasmnim-cli-test"

proc corpus(name: string): string = corpusDir / name

proc ran(args: varargs[string]): CliResult = runCli(@args)

suite "cli: running":
  setup: createDir(tmp)
  teardown: removeDir(tmp)

  test "calls an export with typed arguments":
    let r = ran("run", "--invoke", "fib", corpus("fib.wat"), "20")
    check r.code == 0
    check r.stdout == "6765:i32\n"
    check ran("run", "--invoke", "fac", corpus("factorial.wat"), "20").stdout == "2432902008176640000:i64\n"

  test "accepts hex, negative and underscored integers":
    check parseArg("0xFF", vtI32).asI32 == 255
    check parseArg("-5", vtI32).asI32 == -5
    check parseArg("4_000", vtI64).asI64 == 4000
    check parseArg("0xFFFFFFFF", vtI32).asI32 == -1
    check parseArg("-0x80000000", vtI32).asI32 == low(int32)
    check parseArg("2.5", vtF64).asF64 == 2.5
    check parseArg("-inf", vtF32).asF32 == NegInf
    check parseArg("nan", vtF64).asF64 != parseArg("nan", vtF64).asF64
    expect WasmError: discard parseArg("4294967296", vtI32)
    expect WasmError: discard parseArg("-2147483649", vtI32)
    expect WasmError: discard parseArg("12x", vtI32)
    expect WasmError: discard parseArg("", vtI64)

  test "reports traps, argument errors and fuel exhaustion":
    let t = ran("run", "--invoke", "div0", corpus("traps.wat"), "0")
    check t.code == 1
    check t.stderr == "trap: integer divide by zero\n"
    check ran("run", "--invoke", "div0", corpus("traps.wat")).stderr.contains("expects 1 argument")
    check ran("run", "--invoke", "fac", corpus("factorial.wat"), "abc").code == 1
    let f = ran("run", "--fuel", "100", "--invoke", "forever", corpus("traps.wat"))
    check f.code == 1
    check "fuel" in f.stderr

  test "without an entry point it lists the exports":
    let r = ran("run", corpus("fib.wat"))
    check r.code == 1
    check "fib_iter" in r.stderr

  test "provides the env print functions and runs main":
    let src = tmp / "hello.wat"
    writeFile(src, """(module
      (import "env" "print_i32" (func $p (param i32)))
      (import "env" "putc" (func $c (param i32)))
      (func (export "main") (call $p (i32.const -7)) (call $c (i32.const 104)) (call $c (i32.const 105))))""")
    check ran("run", src).stdout == "-7\nhi"

  test "unknown imports are reported as link errors":
    let r = ran("run", "--invoke", "run", corpus("imports.wat"), "1")
    check r.code == 1
    check r.stderr.startsWith("link error:")

suite "cli: other commands":
  setup: createDir(tmp)
  teardown: removeDir(tmp)

  test "validate accepts good modules and rejects bad ones":
    check ran("validate", corpus("sieve.wat")).stdout == "ok\n"
    let bad = tmp / "bad.wat"
    writeFile(bad, "(module (func (result i32) i64.const 1))")
    let r = ran("validate", bad)
    check r.code == 1
    check r.stderr.startsWith("invalid:")
    writeFile(bad, "(module (func")
    check ran("validate", bad).stderr.startsWith("malformed:")

  test "wat2wasm writes a binary that other commands accept":
    let bin = tmp / "fib.wasm"
    let r = ran("wat2wasm", corpus("fib.wat"), "-o", bin)
    check r.code == 0
    check readFile(bin)[0 ..< 4] == "\0asm"
    check ran("validate", bin).stdout == "ok\n"
    check ran("run", "--invoke", "fib_iter", bin, "30").stdout == "832040:i64\n"

  test "dump summarises a module":
    let r = ran("dump", corpus("imports.wat"))
    check r.code == 0
    check "env.log: func (i32) -> ()" in r.stdout
    check "run: func 3 (i32) -> (i32)" in r.stdout
    check "env.mem: memory 1..2 pages" in r.stdout

  test "wasm2wat output assembles to the same bytes":
    for name in ["control", "memory", "numeric", "table", "globals", "strings"]:
      let text = tmp / name & ".wat"
      check ran("wasm2wat", corpus(name & ".wat"), "-o", text).code == 0
      let a = tmp / name & ".a.wasm"
      let b = tmp / name & ".b.wasm"
      check ran("wat2wasm", corpus(name & ".wat"), "-o", a).code == 0
      check ran("wat2wasm", text, "-o", b).code == 0
      check readFile(a) == readFile(b)

  test "usage errors":
    check ran().code == 2
    check ran("help").code == 0
    check ran("frobnicate", "x").code == 2
    check ran("run").code == 2
    check ran("run", "--fuel", "0", "x").code == 2
    check ran("validate", tmp / "missing.wasm").stderr.contains("cannot read")
