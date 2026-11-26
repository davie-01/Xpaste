import AppKit

/// 卡片和空格预览读取条目富文本的规则。
public enum RichText {
    /// 读取顺序与原版一致：flat-rtfd → rtfd → rtf，取第一个能解码的表示。
    /// 同时有 RTF 和 RTFD 时先用 RTFD，网页正文里的图片才不会丢。
    public static let readOrder = [ClipType.flatRTFD, ClipType.rtfd, ClipType.rtf]

    public static func decode(_ item: ClipItemSnapshot) -> NSAttributedString? {
        for type in readOrder {
            guard let data = item.data(for: type) else { continue }
            let rich = type == ClipType.rtf
                ? NSAttributedString(rtf: data, documentAttributes: nil)
                : NSAttributedString(rtfd: data, documentAttributes: nil)
            if let rich { return rich }
        }
        return nil
    }

    /// 卡片缓存的写法：截取的开头里有附件时写成 RTFD，保留图片；否则仍写普通 RTF。
    public static func encodePreview(_ head: NSAttributedString) -> Data? {
        let range = NSRange(location: 0, length: head.length)
        var hasAttachment = false
        head.enumerateAttribute(.attachment, in: range) { value, _, stop in
            if value != nil { hasAttachment = true; stop.pointee = true }
        }
        return hasAttachment
            ? head.rtfd(from: range, documentAttributes: [:])
            : head.rtf(from: range, documentAttributes: [:])
    }

    /// 读卡片缓存：以 `{\rtf` 开头的是普通 RTF（旧缓存都是这种），否则按 RTFD 解码。
    public static func decodePreview(_ data: Data) -> NSAttributedString? {
        if data.starts(with: Array("{\\rtf".utf8)) { return NSAttributedString(rtf: data, documentAttributes: nil) }
        return NSAttributedString(rtfd: data, documentAttributes: nil) ?? NSAttributedString(rtf: data, documentAttributes: nil)
    }
}

// MARK: HTML 回退（XPaste 的增强）

/// 没有 RTF、RTFD 时，从 `public.html` 转出富文本给卡片和预览显示（用户决定，2026-11-27）。
/// WPS 只给 HTML 和它私有的 RTF；私有 RTF 解出来字体全是 Helvetica 10.5、红色高亮也丢了，HTML 能还原字体、字号、颜色和高亮。
/// 原版不这样做：它的卡片和预览只认 flat-rtfd → rtfd → rtf。粘贴仍回放原始 HTML，转换结果只用于显示。
extension RichText {
    /// 超过这个大小的 HTML 不转换，退回纯文本。转换要在主线程跑 WebKit，太大会卡住界面。
    public static let htmlLimit = 2 * 1024 * 1024

    /// 先按 flat-rtfd → rtfd → rtf 取，都没有时再转 `public.html`。HTML 转换用到 WebKit，只能在主线程调用。
    @MainActor
    public static func decodeIncludingHTML(_ item: ClipItemSnapshot) -> NSAttributedString? {
        decode(item) ?? item.data(for: ClipType.html).flatMap(decodeHTML)
    }

    /// 把 HTML 转成富文本：先去掉所有会联网或执行的内容（`sanitizedHTML`），再交给系统转换。
    @MainActor
    public static func decodeHTML(_ data: Data) -> NSAttributedString? {
        guard !data.isEmpty, data.count <= htmlLimit, let html = String(data: data, encoding: .utf8) else { return nil }
        let clean = Data(sanitizedHTML(html).utf8)
        let rich = NSAttributedString(html: clean, options: [.characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        return rich.flatMap { $0.length > 0 ? $0 : nil }
    }

    /// 转换前的清理：去掉脚本、图片、外部样式表、框架、媒体、`<base>`、自动跳转，
    /// 去掉会取资源的属性（src、srcset、background、poster、data），样式里的 `url()` 和 `@import` 换掉。
    /// 文字、内联样式和 `<style>` 里的字体颜色规则都留着。
    public static func sanitizedHTML(_ html: String) -> String {
        var text = html
        func replace(_ pattern: String, with template: String = "") {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        replace(#"<script\b[^>]*>.*?</script\s*>"#)
        replace(#"<script\b[^>]*>"#)
        replace(#"<(iframe|object|embed|applet|frameset|video|audio|picture)\b[^>]*>.*?</\1\s*>"#)
        replace(#"</?(img|image|link|base|iframe|frame|frameset|object|embed|applet|video|audio|source|track|picture|input)\b[^>]*>"#)
        replace(#"<meta\b[^>]*http-equiv[^>]*>"#)
        replace(#"\s(src|srcset|background|poster|data|lowsrc|dynsrc)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#)
        // 样式里的资源引用只在 <style> 块和 style 属性里出现；正文里写着 url( 的文字不动。
        text = rewriteStyles(in: text)
        return text
    }

    private static func rewriteStyles(in html: String) -> String {
        guard let blocks = try? NSRegularExpression(pattern: #"(<style\b[^>]*>)(.*?)(</style\s*>)|(\sstyle\s*=\s*)("[^"]*"|'[^']*')"#,
                                                    options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let url = try? NSRegularExpression(pattern: #"url\s*\([^)]*\)"#, options: [.caseInsensitive]),
              let importRule = try? NSRegularExpression(pattern: #"@import\b[^;]*;?"#, options: [.caseInsensitive])
        else { return html }
        let source = html as NSString
        var result = ""
        var cursor = 0
        for match in blocks.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            var css = source.substring(with: match.range)
            css = importRule.stringByReplacingMatches(in: css, range: NSRange(location: 0, length: (css as NSString).length), withTemplate: "")
            css = url.stringByReplacingMatches(in: css, range: NSRange(location: 0, length: (css as NSString).length), withTemplate: "none")
            result += css
            cursor = NSMaxRange(match.range)
        }
        result += source.substring(from: cursor)
        return result
    }
}
