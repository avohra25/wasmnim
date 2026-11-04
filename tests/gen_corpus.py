#!/usr/bin/env python3
"""Regenerates tests/corpus/*.wasm.hex from the .wat files using wasmtime's
text-format assembler. It is only needed when a corpus file changes; the Nim
tests read the stored hex and never need Python.

    python3 -m venv /tmp/v && /tmp/v/bin/pip install wasmtime
    /tmp/v/bin/python tests/gen_corpus.py
"""
import pathlib
import wasmtime

root = pathlib.Path(__file__).parent / "corpus"
for wat in sorted(root.glob("*.wat")):
    data = wasmtime.wat2wasm(wat.read_text())
    wat.with_suffix(".wasm.hex").write_text(bytes(data).hex() + "\n")
    print(f"{wat.name}: {len(data)} bytes")
