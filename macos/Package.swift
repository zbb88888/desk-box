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
    ],
    targets: [
        .target(name: "DeskBoxCore"),
        .target(name: "DeskBoxVZ", dependencies: ["DeskBoxCore"]),
        .executableTarget(
            name: "dbx-poc",
            dependencies: ["DeskBoxCore", "DeskBoxVZ"]
        ),
        .testTarget(name: "DeskBoxCoreTests", dependencies: ["DeskBoxCore", "DeskBoxVZ"]),
        .testTarget(name: "ConformanceTests", dependencies: ["DeskBoxCore"]),
    ]
)
