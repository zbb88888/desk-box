# M4：fuzz 与 parser 强化面板

状态：已完成（Swift + C 两路 fuzz 运行 pass，exit=0）；关联 `docs/design/m2-roadmap.md`、`docs/security/security-verification-matrix.md`（会同 INV-05/06/07 的 corpus 检验需要）。

## 进度

- ✅ `macos/fuzz/c-harness.c` + `macos/scripts/run-fuzz.sh`：guest C 解析家族（parse_argv/extract_hex_field/ws_extract_string/ws_extract_u64/parse_small_int）以 **Clang -fsanitize=address,undefined** 调用 20000 round × 30+ 扰乱种子；ASAN/UBSAN 无污点；
- ✅ `macos/Tests/FuzzTests/SwiftFuzzTests.swift`：
  - ControlFrame decoder 变异 + tampered magic + 收尾截断；
  - manifest/SBOM/WS/Broker JSON 空/截断/垃圾 payload 的 fail-closed 验证；
  - OCI policy 多样组合预期表（DBX_/PATH/HOME/USER/首字符数字/过长/空值的 deny/allow 对）；
  - HexCoder 处理各长度/字符；；
- ✅ `docs/security/fuzz-findings.md`：记录出样与中性证伪流程；
- ✅ 并发症修复记录：`parse_argv` 按 owner-search `]` 切防截侵（M2-3b）；
- 下一步：fuzz 跑入 CI 日例、ground-truth corpus 独立跟踪版本、release 签名链接通。

## 1. 目标

为我们已经交付的 parser / codec 面建立可回归、可证伪的模糊测试（作为可核验代码发布）：

- **macOS Swift 面**：`ControlFrame` decoder（跳行/截断/随机 byte corpus + targeted 变异）、manifest/opcode 解析、OCI policy、guest sbom JSON、hex 解码；
- **Guest C 面**：`parse_argv`、`extract_hex_field`、`ws_extract_string`、`ws_extract_u64`、`parse_small_int`、`parse_timeout_seconds` —— 在 macOS 本地用 **Clang `-fsanitize=address,undefined`** 的 host build 运行（`DBX_TEST_NO_MAIN` 服务已有）；
- 输出要求：全程 **无 ASAN/UBSAN taint、无 crash、bounded time**；任何发现都以 bug 记录/修复跟踪，不做主观淡化；
- 与 CI 联动：`swift test` 已经包含 ground-truth 样例集；fuzz 随机变异视作开发者长时本钱。

## 2. 整理图

```
macos/
├── Tests/FuzzTests/            # Swift decoder/policy fuzz（分批以 XCTest 接管）
├── fuzz/
│   ├── c-harness.c             # 调 guest-bootstrap.c 文件级函数（DBX_TEST_NO_MAIN）
│   └── corpus/                 # seed corpus（小 已确认涵盖面）
└── scripts/run-fuzz.sh         # 一遍通过脚本（本地/CI）
```

## 3. 具体覆盖项

| 目标 | 方法 | 合格 |
|------|------|------|
| ControlFrame decode | 合法帧 + 边界内变异（magic/length/序列/超长 payload） | 全部 reject 或 accept 当且仅当语义正确，不 crash |
| JSON decoder（manifest/sbom/oci） | Empty/partial/garbage/嵌套变异 | 类 object 报错而不为 crash/loop |
| OciPolicyValidator | 枚举负面样例集合 + 随机组合 | 不可突破既定 deny |
| HexCoder | 奇/偶/错误字符/超长 | Reporter或 nil，不 crash |
| Guest C parse family | 全变形（NULL bytes、超长现场字、\"../\"、大整数） | 无 ASAN/UBSAN 污点、结果正确 |

## 4. 实施步骤

1. `macos/fuzz/c-harness.c`：调 guest-bootstrap.c 中的 parse 函数，逐个验证；
2. `macos/fuzz/corpus/`：对本 phase 接到的人猜测乱参数；
3. `macos/scripts/run-fuzz.sh`：clang -fsanitize 编译 → corpus + mutation 执行；
4. `macos/Tests/FuzzTests/SwiftFuzzTests.swift`：每次 swift test 跑的小规模地面验证；
5. 记录任何发现到 docs/security/fuzz-findings.md；无发现也恢复。

## 5. 非目标
- 不引入分布式 fuzzing service（oss-fuzz/libfuzzer 集成）；本阶段目标是无 ASAN 污点 + 结果确定性；
- 不动现有 verified 行为：如果是发现 bug，另起 ticket 小步修复，不用大信念读成乱；
- 不引入 format-string fuzz或双语案例堆砌；随供应链/Windows phase 的第二折属后续。