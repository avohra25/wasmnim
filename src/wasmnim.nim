## wasmnim: a WebAssembly interpreter written from scratch in Nim.
import wasmnim/[errors, types, opcodes, reader, decode, encode, wat, validate,
                values, store, interp, instance, disasm, cli]
export errors, types, opcodes, reader, decode, encode, wat, validate,
       values, store, interp, instance, disasm, cli

when isMainModule:
  import std/os
  let res = runCli(commandLineParams())
  stdout.write res.stdout
  stderr.write res.stderr
  quit res.code
