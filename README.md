# wasmnim

A WebAssembly interpreter written from scratch in Nim, with no dependencies
beyond the standard library.

**Status: work in progress.** The binary decoder, binary encoder and text-format
(WAT) parser are done; the validator and interpreter are being added one commit
at a time.

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
- A corpus of WAT programs in `tests/corpus/`. The tests assemble each one with
  `parseWat` and check the result against the bytes the reference assembler in
  wasmtime produces (`tests/gen_corpus.py` regenerates the expected bytes).

## Running the tests

```
make test
```

Requires Nim 2.x and a C compiler.

## License

MIT
