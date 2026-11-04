## The `wasmnim` command-line tool. `runCli` is separate from `main` so the
## tests can drive it without spawning a process.

import std/[os, strutils, parseutils, math]
import errors, types, opcodes, decode, encode, wat, validate, values, store,
       interp, instance, disasm

type CliResult* = object
  code*: int
  stdout*, stderr*: string

const usage* = """wasmnim - a WebAssembly interpreter

usage:
  wasmnim run [--invoke NAME] [--fuel N] FILE [ARG...]   run an exported function
  wasmnim validate FILE                                  check that a module is valid
  wasmnim dump FILE                                      summarise types, imports, exports
  wasmnim wasm2wat FILE [-o OUT]                         print a module as text
  wasmnim wat2wasm FILE [-o OUT]                         assemble text into a binary module
  wasmnim help                                           show this message

FILE is a binary module (.wasm) or WebAssembly text (.wat); the format is
detected from the first bytes. `run` calls `_start` or `main` unless --invoke
names another export. Arguments are parsed using the parameter types of the
function. Imports from the module `env` named print_i32, print_i64, print_f32,
print_f64 and putc are provided and write to standard output."""

proc loadModule*(path: string): Module =
  let raw = try: readFile(path) except IOError: raise newException(WasmError, "cannot read " & path)
  if raw.len >= 4 and raw[0 ..< 4] == "\0asm":
    var bytes = newSeq[byte](raw.len)
    for i, c in raw: bytes[i] = byte(c)
    decodeModule(bytes)
  else:
    parseWat(raw)

proc parseArg*(s: string, vt: ValType): Value =
  proc bad(): ref WasmError =
    newException(WasmError, "cannot parse `" & s & "` as " & $vt)
  case vt
  of vtI32, vtI64:
    var n: BiggestInt
    let t = s.replace("_", "")
    let neg = t.startsWith("-")
    let body = if neg or t.startsWith("+"): t[1 .. ^1] else: t
    var u: BiggestUInt
    let used =
      if body.startsWith("0x") or body.startsWith("0X"): parseHex(body, u)
      else: parseBiggestUInt(body, u)
    if used == 0 or used != body.len: raise bad()
    n = cast[BiggestInt](u)
    if neg: n = -n
    if vt == vtI32:
      if (not neg and u > 0xFFFF_FFFF'u64) or (neg and u > 0x8000_0000'u64): raise bad()
      i32Val(cast[int32](uint32(cast[uint64](n) and 0xFFFF_FFFF'u64)))
    else: i64Val(int64(n))
  of vtF32, vtF64:
    var f: float
    let low = s.toLowerAscii
    if low in ["nan", "+nan", "-nan"]: f = NaN
    elif low in ["inf", "+inf"]: f = Inf
    elif low == "-inf": f = -Inf
    elif parseFloat(s, f) != s.len: raise bad()
    if vt == vtF32: f32Val(float32(f)) else: f64Val(f)

proc describe(m: Module): string =
  var lines: seq[string]
  lines.add "types:"
  for i, t in m.types: lines.add "  [" & $i & "] " & $t
  lines.add "imports:"
  for imp in m.imports:
    var d = $imp.kind
    case imp.kind
    of ekFunc: d.add " " & $m.types[int(imp.typeIdx)]
    of ekTable: d.add " " & $imp.table.min & (if imp.table.hasMax: ".." & $imp.table.max else: "")
    of ekMemory: d.add " " & $imp.mem.min & (if imp.mem.hasMax: ".." & $imp.mem.max else: "") & " pages"
    of ekGlobal: d.add " " & (if imp.global.mut: "mut " else: "") & $imp.global.vt
    lines.add "  " & imp.module & "." & imp.name & ": " & d
  lines.add "exports:"
  let fb = m.importCount(ekFunc)
  for e in m.exports:
    var d = $e.kind & " " & $e.idx
    if e.kind == ekFunc:
      let k = int(e.idx) - fb
      if k >= 0 and k < m.funcs.len: d.add " " & $m.types[int(m.funcs[k])]
      else: d.add " (imported)"
    lines.add "  " & e.name & ": " & d
  lines.add "functions: " & $m.funcs.len & " defined, " & $fb & " imported"
  var instrs = 0
  for b in m.bodies: instrs += b.code.len
  lines.add "instructions: " & $instrs
  for i, mem in m.mems:
    lines.add "memory " & $i & ": " & $mem.min & (if mem.hasMax: ".." & $mem.max else: "") & " pages"
  for i, t in m.tables:
    lines.add "table " & $i & ": " & $t.min & (if t.hasMax: ".." & $t.max else: "") & " entries"
  lines.add "globals: " & $m.globals.len
  lines.add "data segments: " & $m.datas.len & ", element segments: " & $m.elems.len
  if m.hasStart: lines.add "start: function " & $m.start
  lines.join("\n") & "\n"

proc hostEnv(output: ref string): Imports =
  var imps: Imports
  template printer(name: string, vt: ValType, conv: untyped) =
    imps.defineFunc("env", name, funcType([vt]), proc (a: seq[Value]): seq[Value] =
      let v {.inject.} = a[0]
      output[].add conv & "\n"
      @[])
  printer("print_i32", vtI32, $v.asI32)
  printer("print_i64", vtI64, $v.asI64)
  printer("print_f32", vtF32, $v.asF32)
  printer("print_f64", vtF64, $v.asF64)
  imps.defineFunc("env", "putc", funcType([vtI32]), proc (a: seq[Value]): seq[Value] =
    output[].add char(a[0].asI32 and 0xFF)
    @[])
  imps

proc writeOut(path: string, data: string): bool =
  try:
    writeFile(path, data)
    true
  except IOError:
    false

proc runCli*(args: seq[string]): CliResult =
  template ok(s: string) = result.stdout = s
  template die(s: string, rc = 1) =
    result.stderr = s & "\n"
    result.code = rc
    return
  if args.len == 0 or args[0] in ["help", "-h", "--help"]:
    ok usage & "\n"
    if args.len == 0: result.code = 2
    return
  let cmd = args[0]
  var rest = args[1 .. ^1]
  # option parsing shared by the commands
  var outPath, entry = ""
  var fuel = int64.high
  var positional: seq[string]
  var i = 0
  while i < rest.len:
    let a = rest[i]
    if positional.len > 0 and cmd == "run":     # everything after FILE belongs to the program
      positional.add a
    elif a in ["-o", "--output"]:
      if i + 1 >= rest.len: die "missing value for " & a, 2
      inc i; outPath = rest[i]
    elif a == "--invoke":
      if i + 1 >= rest.len: die "missing value for --invoke", 2
      inc i; entry = rest[i]
    elif a == "--fuel":
      if i + 1 >= rest.len: die "missing value for --fuel", 2
      inc i
      var n: BiggestInt
      if parseBiggestInt(rest[i], n) != rest[i].len or n <= 0: die "--fuel needs a positive integer", 2
      fuel = int64(n)
    elif a.startsWith("-") and a.len > 1: die "unknown option " & a, 2
    else: positional.add a
    inc i
  if positional.len == 0: die "missing FILE\n\n" & usage, 2
  let path = positional[0]
  try:
    case cmd
    of "validate":
      var m = loadModule(path)
      validate(m)
      ok "ok\n"
    of "dump":
      var m = loadModule(path)
      validate(m)
      ok describe(m)
    of "wasm2wat":
      let m = loadModule(path)
      let text = disassemble(m)
      if outPath.len > 0:
        if not writeOut(outPath, text): die "cannot write " & outPath
      else: ok text
    of "wat2wasm":
      let m = loadModule(path)
      var checked = m                # validation rewrites branch targets, so check a copy
      validate(checked)
      let bytes = encodeModule(m)
      var s = newString(bytes.len)
      for k, b in bytes: s[k] = char(b)
      let dest = if outPath.len > 0: outPath else: path.changeFileExt("wasm")
      if not writeOut(dest, s): die "cannot write " & dest
      ok "wrote " & dest & " (" & $bytes.len & " bytes)\n"
    of "run":
      let m = loadModule(path)
      let output = new string
      output[] = ""
      let inst = instantiate(m, hostEnv(output))
      var name = entry
      if name.len == 0:
        for cand in ["_start", "main"]:
          if inst.hasExport(cand): name = cand; break
      if name.len == 0:
        var names: seq[string]
        for e in m.exports:
          if e.kind == ekFunc: names.add e.name
        die "no `_start` or `main` export; use --invoke with one of: " & names.join(", ")
      let fn = inst.getFunc(name)
      let given = positional[1 .. ^1]
      if given.len != fn.ft.params.len:
        die name & " expects " & $fn.ft.params.len & " argument(s) " & $fn.ft & ", got " & $given.len
      var vals: seq[Value]
      for k, s in given: vals.add parseArg(s, fn.ft.params[k])
      try:
        let res = invoke(fn, vals, fuel)
        var text = output[]
        for r in res: text.add $r & "\n"
        ok text
      except Trap as e:
        result.stdout = output[]
        die "trap: " & e.msg
    else:
      die "unknown command `" & cmd & "`\n\n" & usage, 2
  except WasmError as e:
    let prefix =
      if e of DecodeError: "malformed: "
      elif e of ValidationError: "invalid: "
      elif e of LinkError: "link error: "
      else: "error: "
    die prefix & e.msg
