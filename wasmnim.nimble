# Package
version       = "0.1.0"
author        = "Aryan Vohra"
description   = "A WebAssembly interpreter written from scratch in Nim"
license       = "MIT"
srcDir        = "src"
bin           = @["wasmnim"]

# Dependencies
requires "nim >= 2.0.0"

task test, "Run the test suite":
  for f in listFiles("tests"):
    if f.endsWith(".nim") and "test_" in f:
      exec "nim c -r -d:release --hints:off " & f
