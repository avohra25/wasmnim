## Replays tests/corpus/exec.fixtures, which records what wasmtime computed for
## every pure corpus function on a few thousand argument combinations.
import std/[unittest, os, strutils, tables, math]
import ../src/wasmnim
import helpers

const corpusDir = currentSourcePath().parentDir / "corpus"

proc parseValue(tok: string): Value =
  let parts = tok.split(':')
  let bits = parseHexInt(parts[1]).uint64
  case parts[0]
  of "i32": Value(vt: vtI32, bits: bits)
  of "i64": Value(vt: vtI64, bits: bits)
  of "f32": Value(vt: vtF32, bits: bits)
  else: Value(vt: vtF64, bits: bits)

proc isNan(v: Value): bool =
  case v.vt
  of vtF32: v.asF32.classify == fcNan
  of vtF64: v.asF64.classify == fcNan
  else: false

proc same(a, b: Value): bool =
  ## Bit-for-bit, except that any NaN equals any other NaN: the spec lets
  ## implementations pick the payload for arithmetic NaNs.
  a.vt == b.vt and (a.bits == b.bits or (a.isNan and b.isNan))

suite "differential: wasmnim agrees with wasmtime":
  var instances = initTable[string, Instance]()
  var counts = initCountTable[string]()
  var failures: seq[string]
  var total = 0
  for line in readFile(corpusDir / "exec.fixtures").splitLines:
    if line.len == 0: continue
    let halves = line.split(" => ")
    let left = halves[0].splitWhitespace
    let prog = left[0]
    let fname = left[1]
    if prog notin instances: instances[prog] = instantiate(decodeModule(hexBytes(
      readFile(corpusDir / prog & ".wasm.hex").strip())))
    var args: seq[Value]
    for t in left[2 .. ^1]: args.add parseValue(t)
    var want: seq[Value]
    let wantTrap = halves[1].strip == "trap"
    if not wantTrap:
      for t in halves[1].splitWhitespace: want.add parseValue(t)
    var got: seq[Value]
    var trapped = false
    try:
      got = instances[prog].callWithFuel(fname, 5_000_000, args)
    except Trap:
      trapped = true
    inc total
    counts.inc prog & "." & fname
    var ok = trapped == wantTrap
    if ok and not trapped:
      ok = got.len == want.len
      if ok:
        for i in 0 ..< got.len:
          if not same(got[i], want[i]): ok = false
    if not ok:
      failures.add line & "   (got " & (if trapped: "trap" else: $got) & ")"

  test "all recorded cases match":
    if failures.len > 0:
      echo failures[0 ..< min(failures.len, 10)].join("\n")
    check failures.len == 0
  test "the fixture file exercises many functions":
    check total > 2000
    check counts.len > 40
