## Robustness: mutated and truncated modules must be rejected with a `WasmError`
## (or run to completion) and never crash with an index error, overflow or
## assertion. Seeds are fixed so a failure is reproducible.
import std/[unittest, os, strutils, random]
import ../src/wasmnim
import helpers

const corpusDir = currentSourcePath().parentDir / "corpus"

proc seeds(): seq[(string, seq[byte])] =
  for f in walkFiles(corpusDir / "*.wasm.hex"):
    result.add (f.splitFile.name.replace(".wasm", ""), hexBytes(readFile(f).strip()))

proc tryRun(data: seq[byte]): string =
  ## Returns "" on a clean outcome, otherwise a description of the crash.
  try:
    var m = decodeModule(data)
    validate(m)           # also guards the type indices used below
    var imps: Imports
    for imp in m.imports:       # satisfy imports with inert stand-ins
      case imp.kind
      of ekFunc:
        let ft = m.types[int(imp.typeIdx)]
        imps.define(imp.module, imp.name, externFunc(hostFunc(ft, proc (a: seq[Value]): seq[Value] =
          for t in ft.results: result.add zero(t))))
      of ekMemory: imps.define(imp.module, imp.name, externMemory(newMemory(imp.mem.min, imp.mem.max, imp.mem.hasMax)))
      of ekTable: imps.define(imp.module, imp.name, externTable(newTable(imp.table.min, imp.table.max, imp.table.hasMax)))
      of ekGlobal: imps.define(imp.module, imp.name, externGlobal(newGlobal(zero(imp.global.vt), imp.global.mut)))
    let inst = instantiate(m, imps)
    for e in inst.module.exports:
      if e.kind == ekFunc:
        let f = inst.funcs[int(e.idx)]
        var args: seq[Value]
        for t in f.ft.params: args.add zero(t)
        try:
          discard invoke(f, args, 20_000)
        except Trap:
          discard
  except WasmError:
    discard
  except CatchableError as e:
    return $e.name & ": " & e.msg
  except Defect as e:
    return $e.name & ": " & e.msg & "\n" & e.getStackTrace()
  ""

suite "fuzz: malformed input never crashes the engine":
  test "every prefix of every corpus module":
    for (name, data) in seeds():
      for n in 0 ..< data.len:
        let r = tryRun(data[0 ..< n])
        check r == ""
        if r != "": echo name, " truncated to ", n, ": ", r; break

  test "single byte mutations":
    var rng = initRand(20261104)
    for (name, data) in seeds():
      for round in 0 ..< 400:
        var d = data
        d[rng.rand(d.high)] = byte(rng.rand(255))
        let r = tryRun(d)
        check r == ""
        if r != "": echo name, " round ", round, ": ", r; break

  test "bursts of mutations and insertions":
    var rng = initRand(7)
    for (name, data) in seeds():
      for round in 0 ..< 300:
        var d = data
        for _ in 0 ..< rng.rand(1 .. 6):
          case rng.rand(2)
          of 0: d[rng.rand(d.high)] = byte(rng.rand(255))
          of 1: d.insert(byte(rng.rand(255)), rng.rand(d.high))
          else:
            if d.len > 9: d.delete(rng.rand(8 .. d.high))
        let r = tryRun(d)
        check r == ""
        if r != "": echo name, " round ", round, ": ", r; break

  test "random bytes after a valid header":
    var rng = initRand(99)
    for round in 0 ..< 2000:
      var d = @[byte 0, 0x61, 0x73, 0x6D, 1, 0, 0, 0]
      for _ in 0 ..< rng.rand(0 .. 40): d.add byte(rng.rand(255))
      check tryRun(d) == ""

suite "fuzz: the text format":
  test "mutated WAT sources are rejected cleanly":
    var rng = initRand(5)
    for f in walkFiles(corpusDir / "*.wat"):
      let src = readFile(f)
      for round in 0 ..< 150:
        var s = src
        for _ in 0 ..< rng.rand(1 .. 4):
          let at = rng.rand(s.high)
          case rng.rand(2)
          of 0: s[at] = char(rng.rand(32 .. 126))
          of 1: s.delete(at .. min(s.high, at + rng.rand(0 .. 5)))
          else: s.insert($char(rng.rand(32 .. 126)), at)
        try:
          var m = parseWat(s)
          validate(m)
        except WasmError:
          discard
        except CatchableError as e:
          fail()
          echo f.splitFile.name, ": ", e.name, ": ", e.msg
          break
        except Defect as e:
          fail()
          echo f.splitFile.name, ": ", e.name, ": ", e.msg
          break

suite "round trips":
  test "encode . decode is the identity on the corpus":
    for (name, data) in seeds():
      let m = decodeModule(data)
      check encodeModule(m) == encodeModule(decodeModule(encodeModule(m)))
