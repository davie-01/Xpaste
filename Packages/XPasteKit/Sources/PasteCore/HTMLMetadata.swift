import Foundation

/// 从网页 HTML 里取链接卡片要用的标题、配图和站点图标地址。
/// 只看标签和属性，不执行脚本；取到的地址仍要经过 `LinkPolicy` 检查才能访问（L11）。
public struct HTMLMetadata: Equatable, Sendable {
    public var title: String?
    /// 页面自带的配图（og:image、twitter:image），按优先顺序。
    public var images: [URL] = []
    /// 站点图标，按优先顺序；最后总有一个站点根目录下的 favicon.ico。
    public var icons: [URL] = []

    public init(html: String, baseURL: URL) {
        let base = Self.firstMatch(#"<base\s[^>]*>"#, in: html).flatMap { Self.attributes(of: $0)["href"] }
            .flatMap { URL(string: Self.decodeEntities($0), relativeTo: baseURL)?.absoluteURL } ?? baseURL
        func resolve(_ value: String?) -> URL? {
            guard let value = value.map(Self.decodeEntities)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return URL(string: value, relativeTo: base)?.absoluteURL
        }

        var meta: [String: String] = [:]
        for tag in Self.allMatches(#"<meta\s[^>]*>"#, in: html) {
            let attributes = Self.attributes(of: tag)
            guard let key = (attributes["property"] ?? attributes["name"])?.lowercased(), let content = attributes["content"], meta[key] == nil else { continue }
            meta[key] = content
        }
        let pageTitle = Self.firstMatch(#"<title[^>]*>([\s\S]*?)</title>"#, in: html, group: 1)
        title = [meta["og:title"], meta["twitter:title"], pageTitle]
            .compactMap { $0.map(Self.decodeEntities)?.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        images = ["og:image:secure_url", "og:image:url", "og:image", "twitter:image", "twitter:image:src"].compactMap { resolve(meta[$0]) }
            .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }

        // apple-touch-icon 通常比 icon 大，排在前面。
        var touch: [URL] = [], plain: [URL] = []
        for tag in Self.allMatches(#"<link\s[^>]*>"#, in: html) {
            let attributes = Self.attributes(of: tag)
            let rel = attributes["rel"]?.lowercased().split(whereSeparator: \.isWhitespace) ?? []
            guard let url = resolve(attributes["href"]) else { continue }
            if rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed") { touch.append(url) } else if rel.contains("icon") { plain.append(url) }
        }
        var root = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)
        root?.path = "/favicon.ico"
        root?.query = nil
        root?.fragment = nil
        icons = (touch + plain + [root?.url].compactMap { $0 }).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    // MARK: 解析工具

    static func attributes(of tag: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let string = tag as NSString
        for match in regex.matches(in: tag, range: NSRange(location: 0, length: string.length)) {
            let name = string.substring(with: match.range(at: 1)).lowercased()
            let value = (2...4).lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound }.map(string.substring(with:)) ?? ""
            if result[name] == nil { result[name] = value }
        }
        return result
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}"]
        guard let regex = try? NSRegularExpression(pattern: #"&(#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z]+);"#) else { return text }
        let string = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            result += string.substring(with: NSRange(location: last, length: match.range.location - last))
            let body = string.substring(with: match.range(at: 1))
            let scalar: Unicode.Scalar? = if body.hasPrefix("#x") || body.hasPrefix("#X") {
                UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init)
            } else if body.hasPrefix("#") {
                UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init)
            } else {
                named[body.lowercased()]?.unicodeScalars.first
            }
            result += scalar.map { String($0) } ?? string.substring(with: match.range)
            last = match.range.location + match.range.length
        }
        return result + string.substring(from: last)
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let string = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: string.length)).map { string.substring(with: $0.range) }
    }

    private static func firstMatch(_ pattern: String, in text: String, group: Int = 0) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        return (text as NSString).substring(with: match.range(at: group))
    }
}
