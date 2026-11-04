# wasmnim

A WebAssembly interpreter written from scratch in Nim, with no dependencies
beyond the standard library.

**Status: work in progress.** The binary decoder is done; the text-format
parser, validator and interpreter are being added one commit at a time.

## What exists so far

- LEB128 reader/writer with the strict checks the spec requires (overlong
  encodings, unused bits, UTF-8 validated names).
- A single instruction table (`src/wasmnim/opcodes.nim`) that records every
  supported opcode, its text name, its immediates and its stack signature.
- A binary decoder for WebAssembly 1.0 modules, plus sign-extension, saturating
  truncation, multi-value block types and `memory.copy` / `memory.fill`.

## Running the tests

```
make test
```

Requires Nim 2.x and a C compiler.

## License

MIT
