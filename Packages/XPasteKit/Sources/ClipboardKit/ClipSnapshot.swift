import CryptoKit
import Foundation

/// 剪贴板上一个 item 的一种表示（一个 UTI 及其原始字节）。
public struct ClipRepresentation: Sendable, Equatable {
    public let type: String
    public let data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

/// 剪贴板上的一个 item，可同时带多种表示（纯文本、RTF、HTML 是同一对象的不同表示）。
public struct ClipItemSnapshot: Sendable, Equatable {
    public let representations: [ClipRepresentation]

    public init(representations: [ClipRepresentation]) {
        self.representations = representations
    }

    public func data(for type: String) -> Data? {
        representations.first { $0.type == type }?.data
    }
}

public enum ClipKind: String, Sendable {
    case text, link, image, color, file, unknown
}

/// 一次复制的不可变快照：保留 item 顺序和每个 item 的全部允许表示。
public struct ClipSnapshot: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let items: [ClipItemSnapshot]
    public let kind: ClipKind
    public let fingerprint: String
    public var capturedAt: Date
    public let sourceBundleID: String?
    public let sourceName: String?

    public init(
        id: UUID = UUID(),
        items: [ClipItemSnapshot],
        capturedAt: Date = Date(),
        sourceBundleID: String? = nil,
        sourceName: String? = nil
    ) {
        self.id = id
        self.items = items
        self.kind = ClipClassifier.kind(of: items)
        self.fingerprint = Self.fingerprint(of: items)
        self.capturedAt = capturedAt
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
    }

    public var plainText: String? {
        let parts = items.compactMap { $0.data(for: ClipType.plainText) }.compactMap { String(data: $0, encoding: .utf8) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    public var fileURLs: [URL] {
        items.compactMap { $0.data(for: ClipType.fileURL) }
            .compactMap { String(data: $0, encoding: .utf8) }
            .compactMap { URL(string: $0) }
    }

    /// 去掉指向这些文件的 item（多文件里有不可用的，只交出可用的部分，审查 11）。一个都不剩时返回 nil。
    public func removingFiles(_ urls: Set<URL>) -> ClipSnapshot? {
        guard !urls.isEmpty else { return self }
        let kept = items.filter { item in
            guard let data = item.data(for: ClipType.fileURL), let string = String(data: data, encoding: .utf8),
                  let url = URL(string: string) else { return true }
            return !urls.contains(url)
        }
        guard kept.contains(where: { $0.data(for: ClipType.fileURL) != nil }) else { return nil }
        return ClipSnapshot(id: id, items: kept, capturedAt: capturedAt, sourceBundleID: sourceBundleID, sourceName: sourceName)
    }

    public var imageData: Data? {
        for item in items {
            if let data = item.data(for: ClipType.png) ?? item.data(for: ClipType.tiff) { return data }
        }
        return nil
    }

    public var byteCount: Int {
        items.reduce(0) { $0 + $1.representations.reduce(0) { $0 + $1.data.count } }
    }

    /// 指纹覆盖全部表示：item 保持原顺序，item 内按类型名排序，避免应用声明顺序不同造成假差异。
    static func fingerprint(of items: [ClipItemSnapshot]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data([1]))
        for item in items {
            hasher.update(data: Data([0xFF]))
            for rep in item.representations.sorted(by: { $0.type < $1.type }) {
                hasher.update(data: Data(rep.type.utf8))
                withUnsafeBytes(of: UInt64(rep.data.count).littleEndian) { hasher.update(bufferPointer: $0) }
                hasher.update(data: rep.data)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum ClipType {
    public static let plainText = "public.utf8-plain-text"
    public static let rtf = "public.rtf"
    public static let html = "public.html"
    public static let url = "public.url"
    public static let fileURL = "public.file-url"
    public static let png = "public.png"
    public static let tiff = "public.tiff"
}

public enum ClipClassifier {
    public static func kind(of items: [ClipItemSnapshot]) -> ClipKind {
        let types = Set(items.flatMap { $0.representations.map(\.type) })
        if types.contains(ClipType.fileURL) { return .file }

        let text = items.lazy.compactMap { $0.data(for: ClipType.plainText) }
            .compactMap { String(data: $0, encoding: .utf8) }.first?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let text, !text.isEmpty {
            if isHexColor(text) { return .color }
            if isWebLink(text) { return .link }
            return .text
        }
        if types.contains(ClipType.url) { return .link }
        if types.contains(ClipType.png) || types.contains(ClipType.tiff) { return .image }
        if types.contains(ClipType.rtf) || types.contains(ClipType.html) { return .text }
        return .unknown
    }

    // 与原版实测一致：恰好 6 位十六进制，# 可有可无；3 位、8 位、rgb()、颜色名都算文本。
    static func isHexColor(_ text: String) -> Bool {
        let hex = text.hasPrefix("#") ? text.dropFirst() : Substring(text)
        return hex.count == 6 && hex.allSatisfy(\.isHexDigit)
    }

    static func isWebLink(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return false }
        return true
    }
}
