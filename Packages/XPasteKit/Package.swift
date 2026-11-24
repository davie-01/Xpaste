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
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
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
