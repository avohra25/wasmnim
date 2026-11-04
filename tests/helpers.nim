import std/strutils

proc hexBytes*(s: string): seq[byte] =
  let h = s.multiReplace((" ", ""), ("\n", ""))
  doAssert h.len mod 2 == 0
  for i in 0 ..< h.len div 2:
    result.add(byte(parseHexInt(h[2 * i .. 2 * i + 1])))

proc toBytes*(s: string): seq[byte] =
  for c in s: result.add(byte(c))
