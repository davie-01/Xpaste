import os

/// 统一的日志和耗时打点（L144）。
///
/// - 按功能分类，在“控制台”里可以按子系统 `com.mars.XPaste` 和类别筛选。
/// - 字符串（错误描述、文件名等）按系统默认记成私密，发布版里看到的是 `<private>`；数字照常显示。
///   不记剪贴板正文、完整路径和令牌。
/// - 耗时打点用 `signposter`，在 Instruments 的 Points of Interest 里能看到每段用了多久。
enum Log {
    static let subsystem = "com.mars.XPaste"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let paste = Logger(subsystem: subsystem, category: "paste")
    static let panel = Logger(subsystem: subsystem, category: "panel")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let files = Logger(subsystem: subsystem, category: "files")
    static let link = Logger(subsystem: subsystem, category: "link")
    static let mcp = Logger(subsystem: subsystem, category: "mcp")

    static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)

    /// 量一段同步代码。
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    /// 量一段异步代码。
    static func measure<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, state) }
        return try await body()
    }
}
