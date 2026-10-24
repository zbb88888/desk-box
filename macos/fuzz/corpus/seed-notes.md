# Fuzz seed corpus（M4）

seed 是内嵌于 `macos/fuzz/c-harness.c` 的 corpus[]（便于一致性 + CI 可重放）。
Swift 侧 corpus 在 `macos/Tests/FuzzTests/SwiftFuzzTests.swift` 中。

无 ASAN/UBSAN 污点视为合格；任何发现走 docs/security/fuzz-findings.md 记录。