// swift-tools-version: 6.0
import PackageDescription

// Desk Box macOS 端（见 docs/adr/0002）。
// DeskBoxCore 承载跨平台契约语义；Windows 端不共享二进制，
// 以同一 contract / conformance 套件对齐（ADR-0001）。
// 部署目标 macOS 14 仅为构建基线：平台能力矩阵 POC 冻结前，
// 不把它当作产品最低版本声明。
let package = Package(
    name: "DeskBoxMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DeskBoxCore", targets: ["DeskBoxCore"]),
        .library(name: "DeskBoxVZ", targets: ["DeskBoxVZ"]),
        .executable(name: "dbx-poc", targets: ["dbx-poc"]),
        .executable(name: "DeskBoxGUI", targets: ["DeskBoxGUI"]),
    ],
    targets: [
        .target(name: "DeskBoxCore"),
        .target(name: "DeskBoxVZ", dependencies: ["DeskBoxCore"]),
        .executableTarget(
            name: "dbx-poc",
            dependencies: ["DeskBoxCore", "DeskBoxVZ"]
        ),
        .executableTarget(
            name: "DeskBoxGUI",
            // M30：复用 DeskBoxPaths（DBX_SUPPORT_ROOT 的唯一解析点），GUI 与 daemon/CLI 对同一状态根目录。
            dependencies: ["DeskBoxVZ"],
            path: "gui/DeskBoxGUI/Sources/DesktopBoxGUI"
        ),
        .testTarget(name: "DeskBoxCoreTests", dependencies: ["DeskBoxCore", "DeskBoxVZ"]),
        .testTarget(name: "ConformanceTests", dependencies: ["DeskBoxCore"]),
        .testTarget(name: "FuzzTests", dependencies: ["DeskBoxCore", "DeskBoxVZ"]),
        // M24a：daemon 协议决策表 + 并发/停机行为（不起 VM）。
        .testTarget(name: "DaemonTests", dependencies: ["dbx-poc", "DeskBoxCore", "DeskBoxVZ"]),
        // M28：GUI 里不依赖界面的逻辑（daemon 客户端 / 进程管理 / 错误呈现）。
        .testTarget(name: "GUITests", dependencies: ["DeskBoxGUI"]),
    ]
)
