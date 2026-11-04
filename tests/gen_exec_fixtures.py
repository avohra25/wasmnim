#!/usr/bin/env python3
"""Runs pure exported functions of the corpus programs under wasmtime on a fixed
set of interesting and pseudo-random arguments and records what happened in
tests/corpus/exec.fixtures. The Nim tests replay the file against wasmnim, so
Python is only needed to regenerate it.

    python3 -m venv /tmp/v && /tmp/v/bin/pip install wasmtime
    /tmp/v/bin/python tests/gen_exec_fixtures.py

Line format:  <program> <function> <args...> => <results...>   or   => trap
Every value is `type:hex-of-raw-bits`.
"""
import pathlib, random, struct
import wasmtime
from wasmtime import Store, Module, Instance

root = pathlib.Path(__file__).parent / "corpus"
PROGRAMS = {
    "numeric": None,                      # every exported function
    "control": ["classify", "select_br", "sum_to", "nested_if", "flat_if",
                "multi", "block_params", "early", "sel", "dead"],
    "fib": ["fib_iter"],
    "factorial": ["fac", "gcd", "collatz_steps"],
    "traps": ["div0", "overflow", "rem_min", "bad_conv", "unreachable"],
}
rng = random.Random(20261104)

I32 = [0, 1, 2, 3, 31, 32, 0x7F, 0x80, 0xFF, 0x7FFF, 0x8000, 0xFFFF, 0x7FFFFFFF,
       0x80000000, 0xFFFFFFFE, 0xFFFFFFFF, 0x12345678]
I64 = [0, 1, 2, 63, 64, 0xFF, 0x80, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0x100000000,
       0x7FFFFFFFFFFFFFFF, 0x8000000000000000, 0xFFFFFFFFFFFFFFFE, 0xFFFFFFFFFFFFFFFF,
       0x0123456789ABCDEF]
F32 = [0x00000000, 0x80000000, 0x3F800000, 0xBF800000, 0x3F000000, 0x40200000, 0xC0200000,
       0x7F800000, 0xFF800000, 0x7FC00000, 0x4F000000, 0xCF000000, 0x4F800000, 0x5F000000,
       0x00000001, 0x7F7FFFFF, 0x3EAAAAAB, 0xBFC00000]
F64 = [0x0000000000000000, 0x8000000000000000, 0x3FF0000000000000, 0xBFF0000000000000,
       0x3FE0000000000000, 0x4004000000000000, 0xC004000000000000, 0x7FF0000000000000,
       0xFFF0000000000000, 0x7FF8000000000000, 0x41E0000000000000, 0xC1E0000000000000,
       0x43E0000000000000, 0x43F0000000000000, 0x0000000000000001, 0x7FEFFFFFFFFFFFFF,
       0x3FD5555555555555, 0xBFF8000000000000, 0x4330000000000001]
POOLS = {"i32": (I32, 32), "i64": (I64, 64), "f32": (F32, 32), "f64": (F64, 64)}

def sample(t):
    pool, bits = POOLS[t]
    return rng.choice(pool) if rng.random() < 0.7 else rng.getrandbits(bits)

def to_py(t, raw):
    if t == "i32": return raw - (1 << 32) if raw >= 1 << 31 else raw
    if t == "i64": return raw - (1 << 64) if raw >= 1 << 63 else raw
    if t == "f32": return struct.unpack("<f", struct.pack("<I", raw))[0]
    return struct.unpack("<d", struct.pack("<Q", raw))[0]

def to_raw(t, v):
    if t == "i32": return v & 0xFFFFFFFF
    if t == "i64": return v & 0xFFFFFFFFFFFFFFFF
    if t == "f32": return struct.unpack("<I", struct.pack("<f", v))[0]
    return struct.unpack("<Q", struct.pack("<d", v))[0]

def fmt(t, raw):
    return f"{t}:{raw:0{POOLS[t][1] // 4}x}"

# keep loops short: bound the "iteration count" style parameters
SMALL = {("fib", "fib_iter"), ("control", "sum_to"), ("factorial", "fac"),
         ("factorial", "collatz_steps"), ("factorial", "gcd")}

out = []
for prog, names in PROGRAMS.items():
    wasm = wasmtime.wat2wasm((root / f"{prog}.wat").read_text())
    store = Store()
    inst = Instance(store, Module(store.engine, wasm), [])
    exports = inst.exports(store)
    for ex in sorted(m for m in (names or [k for k in [e.name for e in Module(store.engine, wasm).exports]])):
        fn = exports[ex]
        ty = fn.type(store)
        params = [str(p) for p in ty.params]
        results = [str(r) for r in ty.results]
        for _ in range(60 if params else 1):
            raws = [sample(t) for t in params]
            if (prog, ex) in SMALL:
                raws = [r % 200 + 1 if t.startswith("i") else r for t, r in zip(params, raws)]
            try:
                res = fn(store, *[to_py(t, r) for t, r in zip(params, raws)])
                if res is None: res = []
                elif not isinstance(res, list): res = [res]
                outs = " ".join(fmt(t, to_raw(t, v)) for t, v in zip(results, res))
            except wasmtime.Trap:
                outs = "trap"
            out.append(f"{prog} {ex} {' '.join(fmt(t, r) for t, r in zip(params, raws))} => {outs}".replace("  ", " "))
(root / "exec.fixtures").write_text("\n".join(out) + "\n")
print(len(out), "cases")
