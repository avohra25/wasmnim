## Error types shared by every stage of the pipeline.

type
  WasmError* = object of CatchableError
    ## Base type for everything that can go wrong.

  DecodeError* = object of WasmError
    ## The binary or text input is malformed.
    offset*: int

  ValidationError* = object of WasmError
    ## The module decoded fine but is not well typed.

  LinkError* = object of WasmError
    ## An import could not be satisfied at instantiation time.

  TrapKind* = enum
    tkUnreachable = "unreachable"
    tkIntDivByZero = "integer divide by zero"
    tkIntOverflow = "integer overflow"
    tkInvalidConversion = "invalid conversion to integer"
    tkOutOfBoundsMemory = "out of bounds memory access"
    tkOutOfBoundsTable = "undefined element"
    tkUninitializedElement = "uninitialized element"
    tkIndirectCallType = "indirect call type mismatch"
    tkCallStackExhausted = "call stack exhausted"
    tkHost = "host error"
    tkOutOfFuel = "all fuel consumed"

  Trap* = object of WasmError
    ## A run-time trap. Execution of the current invocation is aborted.
    kind*: TrapKind

proc newDecodeError*(offset: int, msg: string): ref DecodeError =
  result = newException(DecodeError, msg & " (at offset " & $offset & ")")
  result.offset = offset

proc newTrap*(kind: TrapKind, detail = ""): ref Trap =
  result = newException(Trap, if detail.len > 0: $kind & ": " & detail else: $kind)
  result.kind = kind
