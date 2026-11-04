(module
  (memory (export "memory") 1)
  (data (i32.const 0) "plain" " and \"quoted\"" "\n\t\\")
  (data (i32.const 32) "\u{48}\u{49}\u{20ac}\00\ff")
  (data (i32.const 48) ""))
