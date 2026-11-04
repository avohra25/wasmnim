## The instruction table: one row per opcode with its text name, the kind of
## immediate it carries, a stack signature for plain operators, and the access
## width for memory instructions.
##
## Signatures read `inputs:outputs` with one letter per value:
## `i` = i32, `l` = i64, `f` = f32, `d` = f64.

import std/[tables, strutils]

type
  Imm* = enum
    immNone, immBlock, immLabel, immBrTable, immFunc, immCallIndirect,
    immLocal, immGlobal, immMem, immMemIdx, immI32, immI64, immF32, immF64,
    immMemCopy, immMemFill

  OpInfo* = object
    code*: uint16     ## single byte opcodes as-is, 0xFC-prefixed ones as 0xFC00 + sub
    name*: string
    imm*: Imm
    sig*: string      ## "" for structural instructions handled specially
    width*: int       ## bytes accessed for loads and stores, else 0

const
  opUnreachable* = 0x00'u16
  opNop* = 0x01'u16
  opBlock* = 0x02'u16
  opLoop* = 0x03'u16
  opIf* = 0x04'u16
  opElse* = 0x05'u16
  opEnd* = 0x0B'u16
  opBr* = 0x0C'u16
  opBrIf* = 0x0D'u16
  opBrTable* = 0x0E'u16
  opReturn* = 0x0F'u16
  opCall* = 0x10'u16
  opCallIndirect* = 0x11'u16
  opDrop* = 0x1A'u16
  opSelect* = 0x1B'u16
  opLocalGet* = 0x20'u16
  opLocalSet* = 0x21'u16
  opLocalTee* = 0x22'u16
  opGlobalGet* = 0x23'u16
  opGlobalSet* = 0x24'u16
  opMemorySize* = 0x3F'u16
  opMemoryGrow* = 0x40'u16
  opI32Const* = 0x41'u16
  opI64Const* = 0x42'u16
  opF32Const* = 0x43'u16
  opF64Const* = 0x44'u16
  opPrefixFC* = 0xFC00'u16
  opMemoryCopy* = 0xFC0A'u16
  opMemoryFill* = 0xFC0B'u16

proc o(code: uint16, name: string, imm: Imm, sig: string, width = 0): OpInfo =
  OpInfo(code: code, name: name, imm: imm, sig: sig, width: width)

proc buildTable(): seq[OpInfo] =
  result = @[
    o(0x00, "unreachable", immNone, ""), o(0x01, "nop", immNone, ""),
    o(0x02, "block", immBlock, ""), o(0x03, "loop", immBlock, ""),
    o(0x04, "if", immBlock, ""), o(0x05, "else", immNone, ""),
    o(0x0B, "end", immNone, ""), o(0x0C, "br", immLabel, ""),
    o(0x0D, "br_if", immLabel, ""), o(0x0E, "br_table", immBrTable, ""),
    o(0x0F, "return", immNone, ""), o(0x10, "call", immFunc, ""),
    o(0x11, "call_indirect", immCallIndirect, ""),
    o(0x1A, "drop", immNone, ""), o(0x1B, "select", immNone, ""),
    o(0x20, "local.get", immLocal, ""), o(0x21, "local.set", immLocal, ""),
    o(0x22, "local.tee", immLocal, ""), o(0x23, "global.get", immGlobal, ""),
    o(0x24, "global.set", immGlobal, ""),
    # memory access
    o(0x28, "i32.load", immMem, "i:i", 4), o(0x29, "i64.load", immMem, "i:l", 8),
    o(0x2A, "f32.load", immMem, "i:f", 4), o(0x2B, "f64.load", immMem, "i:d", 8),
    o(0x2C, "i32.load8_s", immMem, "i:i", 1), o(0x2D, "i32.load8_u", immMem, "i:i", 1),
    o(0x2E, "i32.load16_s", immMem, "i:i", 2), o(0x2F, "i32.load16_u", immMem, "i:i", 2),
    o(0x30, "i64.load8_s", immMem, "i:l", 1), o(0x31, "i64.load8_u", immMem, "i:l", 1),
    o(0x32, "i64.load16_s", immMem, "i:l", 2), o(0x33, "i64.load16_u", immMem, "i:l", 2),
    o(0x34, "i64.load32_s", immMem, "i:l", 4), o(0x35, "i64.load32_u", immMem, "i:l", 4),
    o(0x36, "i32.store", immMem, "ii:", 4), o(0x37, "i64.store", immMem, "il:", 8),
    o(0x38, "f32.store", immMem, "if:", 4), o(0x39, "f64.store", immMem, "id:", 8),
    o(0x3A, "i32.store8", immMem, "ii:", 1), o(0x3B, "i32.store16", immMem, "ii:", 2),
    o(0x3C, "i64.store8", immMem, "il:", 1), o(0x3D, "i64.store16", immMem, "il:", 2),
    o(0x3E, "i64.store32", immMem, "il:", 4),
    o(0x3F, "memory.size", immMemIdx, ":i"), o(0x40, "memory.grow", immMemIdx, "i:i"),
    o(0x41, "i32.const", immI32, ":i"), o(0x42, "i64.const", immI64, ":l"),
    o(0x43, "f32.const", immF32, ":f"), o(0x44, "f64.const", immF64, ":d"),
    # i32 comparisons
    o(0x45, "i32.eqz", immNone, "i:i"), o(0x46, "i32.eq", immNone, "ii:i"),
    o(0x47, "i32.ne", immNone, "ii:i"), o(0x48, "i32.lt_s", immNone, "ii:i"),
    o(0x49, "i32.lt_u", immNone, "ii:i"), o(0x4A, "i32.gt_s", immNone, "ii:i"),
    o(0x4B, "i32.gt_u", immNone, "ii:i"), o(0x4C, "i32.le_s", immNone, "ii:i"),
    o(0x4D, "i32.le_u", immNone, "ii:i"), o(0x4E, "i32.ge_s", immNone, "ii:i"),
    o(0x4F, "i32.ge_u", immNone, "ii:i"),
    # i64 comparisons
    o(0x50, "i64.eqz", immNone, "l:i"), o(0x51, "i64.eq", immNone, "ll:i"),
    o(0x52, "i64.ne", immNone, "ll:i"), o(0x53, "i64.lt_s", immNone, "ll:i"),
    o(0x54, "i64.lt_u", immNone, "ll:i"), o(0x55, "i64.gt_s", immNone, "ll:i"),
    o(0x56, "i64.gt_u", immNone, "ll:i"), o(0x57, "i64.le_s", immNone, "ll:i"),
    o(0x58, "i64.le_u", immNone, "ll:i"), o(0x59, "i64.ge_s", immNone, "ll:i"),
    o(0x5A, "i64.ge_u", immNone, "ll:i"),
    # float comparisons
    o(0x5B, "f32.eq", immNone, "ff:i"), o(0x5C, "f32.ne", immNone, "ff:i"),
    o(0x5D, "f32.lt", immNone, "ff:i"), o(0x5E, "f32.gt", immNone, "ff:i"),
    o(0x5F, "f32.le", immNone, "ff:i"), o(0x60, "f32.ge", immNone, "ff:i"),
    o(0x61, "f64.eq", immNone, "dd:i"), o(0x62, "f64.ne", immNone, "dd:i"),
    o(0x63, "f64.lt", immNone, "dd:i"), o(0x64, "f64.gt", immNone, "dd:i"),
    o(0x65, "f64.le", immNone, "dd:i"), o(0x66, "f64.ge", immNone, "dd:i"),
    # i32 arithmetic
    o(0x67, "i32.clz", immNone, "i:i"), o(0x68, "i32.ctz", immNone, "i:i"),
    o(0x69, "i32.popcnt", immNone, "i:i"), o(0x6A, "i32.add", immNone, "ii:i"),
    o(0x6B, "i32.sub", immNone, "ii:i"), o(0x6C, "i32.mul", immNone, "ii:i"),
    o(0x6D, "i32.div_s", immNone, "ii:i"), o(0x6E, "i32.div_u", immNone, "ii:i"),
    o(0x6F, "i32.rem_s", immNone, "ii:i"), o(0x70, "i32.rem_u", immNone, "ii:i"),
    o(0x71, "i32.and", immNone, "ii:i"), o(0x72, "i32.or", immNone, "ii:i"),
    o(0x73, "i32.xor", immNone, "ii:i"), o(0x74, "i32.shl", immNone, "ii:i"),
    o(0x75, "i32.shr_s", immNone, "ii:i"), o(0x76, "i32.shr_u", immNone, "ii:i"),
    o(0x77, "i32.rotl", immNone, "ii:i"), o(0x78, "i32.rotr", immNone, "ii:i"),
    # i64 arithmetic
    o(0x79, "i64.clz", immNone, "l:l"), o(0x7A, "i64.ctz", immNone, "l:l"),
    o(0x7B, "i64.popcnt", immNone, "l:l"), o(0x7C, "i64.add", immNone, "ll:l"),
    o(0x7D, "i64.sub", immNone, "ll:l"), o(0x7E, "i64.mul", immNone, "ll:l"),
    o(0x7F, "i64.div_s", immNone, "ll:l"), o(0x80, "i64.div_u", immNone, "ll:l"),
    o(0x81, "i64.rem_s", immNone, "ll:l"), o(0x82, "i64.rem_u", immNone, "ll:l"),
    o(0x83, "i64.and", immNone, "ll:l"), o(0x84, "i64.or", immNone, "ll:l"),
    o(0x85, "i64.xor", immNone, "ll:l"), o(0x86, "i64.shl", immNone, "ll:l"),
    o(0x87, "i64.shr_s", immNone, "ll:l"), o(0x88, "i64.shr_u", immNone, "ll:l"),
    o(0x89, "i64.rotl", immNone, "ll:l"), o(0x8A, "i64.rotr", immNone, "ll:l"),
    # f32 arithmetic
    o(0x8B, "f32.abs", immNone, "f:f"), o(0x8C, "f32.neg", immNone, "f:f"),
    o(0x8D, "f32.ceil", immNone, "f:f"), o(0x8E, "f32.floor", immNone, "f:f"),
    o(0x8F, "f32.trunc", immNone, "f:f"), o(0x90, "f32.nearest", immNone, "f:f"),
    o(0x91, "f32.sqrt", immNone, "f:f"), o(0x92, "f32.add", immNone, "ff:f"),
    o(0x93, "f32.sub", immNone, "ff:f"), o(0x94, "f32.mul", immNone, "ff:f"),
    o(0x95, "f32.div", immNone, "ff:f"), o(0x96, "f32.min", immNone, "ff:f"),
    o(0x97, "f32.max", immNone, "ff:f"), o(0x98, "f32.copysign", immNone, "ff:f"),
    # f64 arithmetic
    o(0x99, "f64.abs", immNone, "d:d"), o(0x9A, "f64.neg", immNone, "d:d"),
    o(0x9B, "f64.ceil", immNone, "d:d"), o(0x9C, "f64.floor", immNone, "d:d"),
    o(0x9D, "f64.trunc", immNone, "d:d"), o(0x9E, "f64.nearest", immNone, "d:d"),
    o(0x9F, "f64.sqrt", immNone, "d:d"), o(0xA0, "f64.add", immNone, "dd:d"),
    o(0xA1, "f64.sub", immNone, "dd:d"), o(0xA2, "f64.mul", immNone, "dd:d"),
    o(0xA3, "f64.div", immNone, "dd:d"), o(0xA4, "f64.min", immNone, "dd:d"),
    o(0xA5, "f64.max", immNone, "dd:d"), o(0xA6, "f64.copysign", immNone, "dd:d"),
    # conversions
    o(0xA7, "i32.wrap_i64", immNone, "l:i"),
    o(0xA8, "i32.trunc_f32_s", immNone, "f:i"), o(0xA9, "i32.trunc_f32_u", immNone, "f:i"),
    o(0xAA, "i32.trunc_f64_s", immNone, "d:i"), o(0xAB, "i32.trunc_f64_u", immNone, "d:i"),
    o(0xAC, "i64.extend_i32_s", immNone, "i:l"), o(0xAD, "i64.extend_i32_u", immNone, "i:l"),
    o(0xAE, "i64.trunc_f32_s", immNone, "f:l"), o(0xAF, "i64.trunc_f32_u", immNone, "f:l"),
    o(0xB0, "i64.trunc_f64_s", immNone, "d:l"), o(0xB1, "i64.trunc_f64_u", immNone, "d:l"),
    o(0xB2, "f32.convert_i32_s", immNone, "i:f"), o(0xB3, "f32.convert_i32_u", immNone, "i:f"),
    o(0xB4, "f32.convert_i64_s", immNone, "l:f"), o(0xB5, "f32.convert_i64_u", immNone, "l:f"),
    o(0xB6, "f32.demote_f64", immNone, "d:f"),
    o(0xB7, "f64.convert_i32_s", immNone, "i:d"), o(0xB8, "f64.convert_i32_u", immNone, "i:d"),
    o(0xB9, "f64.convert_i64_s", immNone, "l:d"), o(0xBA, "f64.convert_i64_u", immNone, "l:d"),
    o(0xBB, "f64.promote_f32", immNone, "f:d"),
    o(0xBC, "i32.reinterpret_f32", immNone, "f:i"), o(0xBD, "i64.reinterpret_f64", immNone, "d:l"),
    o(0xBE, "f32.reinterpret_i32", immNone, "i:f"), o(0xBF, "f64.reinterpret_i64", immNone, "l:d"),
    # sign extension
    o(0xC0, "i32.extend8_s", immNone, "i:i"), o(0xC1, "i32.extend16_s", immNone, "i:i"),
    o(0xC2, "i64.extend8_s", immNone, "l:l"), o(0xC3, "i64.extend16_s", immNone, "l:l"),
    o(0xC4, "i64.extend32_s", immNone, "l:l"),
    # saturating truncation (0xFC prefix)
    o(0xFC00, "i32.trunc_sat_f32_s", immNone, "f:i"), o(0xFC01, "i32.trunc_sat_f32_u", immNone, "f:i"),
    o(0xFC02, "i32.trunc_sat_f64_s", immNone, "d:i"), o(0xFC03, "i32.trunc_sat_f64_u", immNone, "d:i"),
    o(0xFC04, "i64.trunc_sat_f32_s", immNone, "f:l"), o(0xFC05, "i64.trunc_sat_f32_u", immNone, "f:l"),
    o(0xFC06, "i64.trunc_sat_f64_s", immNone, "d:l"), o(0xFC07, "i64.trunc_sat_f64_u", immNone, "d:l"),
    # bulk memory
    o(0xFC0A, "memory.copy", immMemCopy, "iii:"), o(0xFC0B, "memory.fill", immMemFill, "iii:"),
  ]

let opTable* = buildTable()

proc buildByCode(): Table[uint16, int] =
  for i, e in opTable: result[e.code] = i

proc buildByName(): Table[string, int] =
  for i, e in opTable: result[e.name] = i

let
  byCode = buildByCode()
  byName = buildByName()

proc opInfo*(code: uint16): OpInfo =
  ## Raises KeyError for an unknown opcode; use `isKnownOp` first when probing.
  opTable[byCode[code]]

proc isKnownOp*(code: uint16): bool = code in byCode

proc opByName*(name: string, info: var OpInfo): bool =
  if name in byName:
    info = opTable[byName[name]]
    return true

proc opName*(code: uint16): string =
  if code in byCode: opTable[byCode[code]].name else: "0x" & toHex(int(code), 2).toLowerAscii()
