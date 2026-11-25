// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XPasteKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "ClipboardKit", targets: ["ClipboardKit"]),
        .library(name: "PasteCore", targets: ["PasteCore"]),
        .library(name: "MCPKit", targets: ["MCPKit"]),
        // stdio 转接程序只用这一小块，不带数据层和 GRDB（L87）。
        .library(name: "MCPBridge", targets: ["MCPBridge"]),
    ],
    dependencies: [
        // 写死版本：本目录的 Package.resolved 不入库（xcodebuild 和 swift test 会来回改写它），版本由这里决定。
        // 升级时改这里、跑自检和测试，同时更新 THIRD_PARTY_NOTICES.md。见 Docs/design.md“依赖版本的锁定”。
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0"),
    ],
    targets: [
        .target(name: "ClipboardKit"),
        .target(name: "PasteCore", dependencies: ["ClipboardKit", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "MCPBridge"),
        .target(name: "MCPKit", dependencies: ["PasteCore", "ClipboardKit", "MCPBridge"]),
        .testTarget(name: "ClipboardKitTests", dependencies: ["ClipboardKit"]),
        .testTarget(name: "PasteCoreTests", dependencies: ["PasteCore"]),
        .testTarget(name: "MCPKitTests", dependencies: ["MCPKit", "MCPBridge", "PasteCore", "ClipboardKit"]),
    ]
)
