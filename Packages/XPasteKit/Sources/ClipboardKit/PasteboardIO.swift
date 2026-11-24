import AppKit

public struct ClipSource: Sendable, Equatable {
    public let bundleID: String?
    public let name: String?

    public init(bundleID: String?, name: String?) {
        self.bundleID = bundleID
        self.name = name
    }
}

public enum PasteboardReadResult: Sendable, Equatable {
    case snapshot(ClipSnapshot)
    case skipped(CapturePolicy.SkipReason)
    /// 计数已变但允许的表示都还读不到数据，调用方可做有限次重试。
    case notReady
    /// 读取过程中剪贴板又被改写，本次结果作废。
    case changedDuringRead
}

/// 读取可能在任意线程进行：写入方用延迟提供的数据时，读取会一直等到对方给出数据（R26），不能放在主线程上。
public enum PasteboardReader {
    public static func read(
        from pasteboard: NSPasteboard,
        policy: CapturePolicy,
        source: ClipSource
    ) -> PasteboardReadResult {
        let countBefore = pasteboard.changeCount
        let pbItems = pasteboard.pasteboardItems ?? []

        var allTypes = Set((pasteboard.types ?? []).map(\.rawValue))
        for item in pbItems { allTypes.formUnion(item.types.map(\.rawValue)) }
        let source = declaredSource(in: pasteboard, types: allTypes) ?? source

        if case .skip(let reason) = policy.decide(types: allTypes, sourceBundleID: source.bundleID) {
            return .skipped(reason)
        }

        var items: [ClipItemSnapshot] = []
        for item in pbItems {
            let available = Set(item.types.map(\.rawValue))
            let reps = CapturePolicy.allowedTypes
                .filter(available.contains)
                .compactMap { type -> ClipRepresentation? in
                    guard let data = item.data(forType: .init(type)), !data.isEmpty else { return nil }
                    return ClipRepresentation(type: type, data: data)
                }
            // 只带辅助元信息、没有可用表示的 item 不单独成项。
            if !reps.isEmpty { items.append(ClipItemSnapshot(representations: reps)) }
        }

        guard pasteboard.changeCount == countBefore else { return .changedDuringRead }
        guard !items.isEmpty else { return .notReady }
        return .snapshot(ClipSnapshot(items: items, sourceBundleID: source.bundleID, sourceName: source.name))
    }

    /// nspasteboard.org 约定的 `org.nspasteboard.source`：写入方自报的 bundle ID。
    /// 前台应用不一定是写剪贴板的那个（后台工具、菜单栏应用），有自报的就用它（L40）；值为空表示不愿透露，仍用前台应用。
    static let sourceType = "org.nspasteboard.source"

    static func declaredSource(in pasteboard: NSPasteboard, types: Set<String>) -> ClipSource? {
        guard types.contains(sourceType),
              let bundleID = pasteboard.string(forType: .init(sourceType))?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleID.isEmpty, bundleID.count <= 255 else { return nil }
        // 本机找不到这个应用时名称就用 bundle ID。
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path) }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
        return ClipSource(bundleID: bundleID, name: name ?? bundleID)
    }
}

@MainActor
public enum PasteboardWriter {
    /// 按原 item 结构整体重建后一次写入，并附自身标记。返回写入后的 changeCount；系统没有接受写入时返回 nil（审查 01），
    /// 调用方不应再显示“已复制”、发送 ⌘V 或推进 Stack。
    @discardableResult
    public static func write(_ snapshot: ClipSnapshot, to pasteboard: NSPasteboard, plainTextOnly: Bool = false) -> Int? {
        var pbItems: [NSPasteboardItem] = []
        // 纯文本模式下只要有 item 能得到文本，就只写这些文本 item，不再带出同次复制里的图片等其他 item（审查 GH-02）。
        let textOnly = plainTextOnly && snapshot.kind != .file && snapshot.items.contains { plainText(of: $0) != nil }
        for item in snapshot.items {
            if textOnly, plainText(of: item) == nil { continue }
            let pbItem = NSPasteboardItem()
            // 纯文本模式只对能得到文本的 item 生效；文件和纯图片保持原样。
            if plainTextOnly, snapshot.kind != .file, let text = plainText(of: item) {
                pbItem.setString(text, forType: .string)
            } else {
                for rep in item.representations { pbItem.setData(rep.data, forType: .init(rep.type)) }
            }
            if !pbItem.types.isEmpty { pbItems.append(pbItem) }
        }
        guard let first = pbItems.first else { return nil }
        first.setData(Data(), forType: .init(CapturePolicy.selfMarker))

        pasteboard.clearContents()
        #if DEBUG
        if debugFailWrites { return nil }
        #endif
        guard pasteboard.writeObjects(pbItems) else { return nil }
        return pasteboard.changeCount
    }

    #if DEBUG
    /// 测试用：让写入失败。
    public static var debugFailWrites = false
    #endif

    /// item 的纯文本：优先用已有的纯文本表示，否则从 RTF、HTML 转出。
    static func plainText(of item: ClipItemSnapshot) -> String? {
        if let data = item.data(for: ClipType.plainText), let text = String(data: data, encoding: .utf8) { return text }
        if let data = item.data(for: ClipType.rtf), let rich = NSAttributedString(rtf: data, documentAttributes: nil) { return rich.string }
        if let data = item.data(for: ClipType.html) { return HTMLText.plainText(from: data) }
        return nil
    }
}

/// HTML 转纯文本，不用系统的 HTML 导入（审查 GH-03）：那条路要在主线程上走 WebKit，
/// 页面里引用的外部图片可能让它同步等很久。这里只按标签结构断行、去掉标签、解出实体。
enum HTMLText {
    static func plainText(from data: Data) -> String? {
        guard var html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        // 不显示的部分整段去掉。
        for tag in ["script", "style", "head", "template"] {
            html = html.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        html = html.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        // 源码里的换行和连续空白在 HTML 里只算一个空格。
        html = html.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        html = html.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        html = html.replacingOccurrences(of: "<(td|th)\\b[^>]*>", with: "\t", options: [.regularExpression, .caseInsensitive])
        html = html.replacingOccurrences(of: "</(p|div|li|tr|h[1-6]|blockquote|pre|table|ul|ol|section|article)\\s*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        html = html.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        let text = decodeEntities(html)
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            .replacingOccurrences(of: "\t+", with: "\t", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                                                   "copy": "©", "reg": "®", "hellip": "…", "mdash": "—", "ndash": "–",
                                                   "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "middot": "·", "times": "×"]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(12).firstIndex(of: ";") {
                let name = String(after[..<semi])
                var decoded: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    decoded = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if name.hasPrefix("#") {
                    decoded = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    decoded = named[name]
                }
                if let decoded {
                    result += decoded
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            result += "&"
            rest = after
        }
        return result + rest
    }
}
