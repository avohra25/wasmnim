# wasmnim

A WebAssembly interpreter written from scratch in Nim, with no dependencies
beyond the standard library.

**Status: work in progress.** Decoding, encoding, text parsing, validation and
execution work; the command-line tool is the next commit.

## What exists so far

- LEB128 reader/writer with the strict checks the spec requires (overlong
  encodings, unused bits, UTF-8 validated names).
- A single instruction table (`src/wasmnim/opcodes.nim`) that records every
  supported opcode, its text name, its immediates and its stack signature.
- A binary decoder for WebAssembly 1.0 modules, plus sign-extension, saturating
  truncation, multi-value block types and `memory.copy` / `memory.fill`.
- A binary encoder (`encodeModule`) that writes a `Module` back to bytes.
- A WAT parser (`parseWat`): folded and flat instructions, `$names` for every
  index space, inline `import`/`export`/`data`/`elem`, hex floats, `nan:0x...`
  payloads, string escapes (`\41`, `\u{20ac}`), and block types.
- A validator (`validate`) that type-checks every function body with the spec's
  algorithm (polymorphic stack after `unreachable`/`br`, multi-value blocks) and
  checks the module-level rules: limits, one memory/table, export names, start
  function, constant initialisers, segment offsets, alignment. It also resolves
  every branch to an absolute target so the interpreter never searches for labels.
- An interpreter (`instantiate`, `call`, `invoke`) with host imports, shared
  memories/tables/globals, a start function, bounds-checked segments, and every
  trap the spec defines. Traps are ordinary exceptions (`Trap` with a `kind`).
  Call depth is capped, and an optional fuel budget (`callWithFuel`) stops runaway
  loops.
- A corpus of WAT programs in `tests/corpus/`. The tests assemble each one with
  `parseWat` and check the result against the bytes the reference assembler in
  wasmtime produces (`tests/gen_corpus.py` regenerates the expected bytes).

## Using it as a library

```nim
import wasmnim

let inst = instantiate(parseWat("""
  (module
    (func $fib (export "fib") (param i32) (result i32)
      (if (result i32) (i32.lt_s (local.get 0) (i32.const 2))
        (then (local.get 0))
        (else (i32.add (call $fib (i32.sub (local.get 0) (i32.const 1)))
                       (call $fib (i32.sub (local.get 0) (i32.const 2))))))))"""))
echo inst.call("fib", i32Val(20))[0].asI32   # 6765
```

Host functions are passed as imports:

```nim
var imports: Imports
imports.defineFunc("env", "log", funcType([vtI32]), proc (a: seq[Value]): seq[Value] =
  echo "wasm says ", a[0].asI32
  @[])
```

## How execution works

Every value is a raw `uint64` on one shared stack; a call owns a window of it
holding parameters, then locals, then its operand stack. The validator records
the maximum operand height of each body, so the stack is grown once per call, and
rewrites each `br`, `br_if` and `br_table` to carry its absolute target pc, how
many values to keep and the height to unwind to. The main loop is then a flat
`case` over the opcode with no label bookkeeping.

## Testing

- `test_exec`: classic programs (fib, factorial, sieve), control flow, memory,
  tables, globals, traps, host imports and linking errors.
- `test_validate`: ill-typed modules that must be rejected, and valid ones with
  tricky unreachable code.
- `test_differential`: replays 2,400+ recorded argument/result pairs from
  wasmtime (`tests/gen_exec_fixtures.py` regenerates them), comparing results
  bit for bit and traps as traps.

## Running the tests

```
make test
```

Requires Nim 2.x and a C compiler.

## License

MIT
