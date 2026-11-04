# wasmnim

A WebAssembly interpreter written from scratch in Nim, with no dependencies
beyond the standard library.

It decodes, assembles, validates, runs and disassembles WebAssembly 1.0 modules
(plus sign-extension, saturating truncation, multi-value and bulk
`memory.copy`/`memory.fill`), and ships a small command-line tool.

## Features

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
  Call depth is capped (3000 frames in release builds, 400 in unoptimised ones
  so the native stack stays within 8 MB), and an optional fuel budget (`callWithFuel`) stops runaway
  loops.
- A disassembler (`disassemble`) that prints any module as flat WAT with numeric
  indices. Floats keep their exact bits (`nan:0x...`, `inf`), and the output
  assembles back to the same bytes. It must be given a module as decoded or
  parsed, not one that `validate` has rewritten in place (`instantiate` validates
  a private copy, so instances are always safe).
- A command-line tool (`src/wasmnim/cli.nim`, see below).
- A corpus of WAT programs in `tests/corpus/`. The tests assemble each one with
  `parseWat` and check the result against the bytes the reference assembler in
  wasmtime produces (`tests/gen_corpus.py` regenerates the expected bytes).

## Command line

```
make build                      # writes bin/wasmnim
bin/wasmnim run --invoke fib_iter tests/corpus/fib.wat 30    # 832040:i64
bin/wasmnim wat2wasm prog.wat -o prog.wasm
bin/wasmnim wasm2wat prog.wasm
bin/wasmnim validate prog.wasm  # prints "ok" or the first error
bin/wasmnim dump prog.wasm      # types, imports, exports, memories
```

`run` accepts `.wasm` or `.wat` files (detected from the first bytes), parses
arguments by the parameter types of the function (decimal, `0x` hex, negative,
`1_000` separators, floats), and prints results as `value:type`. Without
`--invoke` it calls `_start` or `main`, and otherwise lists the exports. `--fuel N`
limits executed branches and calls. Modules may import `env.print_i32`,
`print_i64`, `print_f32`, `print_f64` (one line each) and `env.putc`.
A trap prints `trap: <reason>` and exits with status 1; usage errors exit 2.

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

- `test_fuzz`: decodes every prefix of every corpus module, thousands of
  mutated, inserted, deleted and random byte strings, and mutated WAT sources.
  Whatever the input, only a `WasmError` may escape, and anything that
  validates is instantiated and its exports run under a fuel limit.
- `test_disasm` and `test_cli`: WAT to text to bytes round trips on every corpus
  program, exact float printing, and the command line's output and exit codes.
- `test_leb`, `test_decode`, `test_wat`: the lower layers in isolation.

## Running the tests

```
make test
```

Requires Nim 2.x and a C compiler.

## License

MIT
