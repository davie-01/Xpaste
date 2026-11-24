import AppKit

/// 多选后粘贴或复制时写出的内容。规则来自原版实测（Docs/归档/调研/08 第 9.4、9.16 节）。
public enum MultiSelection {
    /// `snapshots` 按面板上的显示顺序排列。
    ///
    /// - 选中项里只要有文本（文本、链接、颜色），就只写文本：各条按显示顺序用换行拼接，
    ///   两条以上时末尾再带一个换行；图片和文件被忽略。和原版一样同时写纯文本和 RTF，
    ///   原来带 RTF 的条目保留格式，其余按无格式拼进去。
    /// - 一条文本都没有时，每个选中项的 item 原样依次写出，一个文件、一张图片各占一个 item。
    /// - `trailingNewline` 为 false 时两条以上也不在末尾加换行（Stack 的全部粘贴，原版视频 00:25 粘完光标紧跟在最后一项后面）。
    public static func compose(_ snapshots: [ClipSnapshot], trailingNewline: Bool = true) -> ClipSnapshot? {
        guard let first = snapshots.first else { return nil }
        if snapshots.count == 1 { return first }

        let texts = snapshots.filter { [.text, .link, .color].contains($0.kind) }
            .compactMap { snapshot in snapshot.plainText.map { (snapshot, $0) } }
            .filter { !$0.1.isEmpty }
        if !texts.isEmpty {
            let trailing = texts.count > 1 && trailingNewline
            let joined = texts.map(\.1).joined(separator: "\n") + (trailing ? "\n" : "")
            let rich = NSMutableAttributedString()
            for (index, (snapshot, plain)) in texts.enumerated() {
                if index > 0 { rich.append(NSAttributedString(string: "\n")) }
                let formatted = snapshot.items.lazy.compactMap { $0.data(for: ClipType.rtf) }.first
                    .flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) }
                // RTF 和纯文本对不上（比如末尾换行不同）时以纯文本为准。
                rich.append(formatted?.string == plain ? formatted! : NSAttributedString(string: plain))
            }
            if trailing { rich.append(NSAttributedString(string: "\n")) }
            var representations = [ClipRepresentation(type: ClipType.plainText, data: Data(joined.utf8))]
            if let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                representations.append(ClipRepresentation(type: ClipType.rtf, data: rtf))
            }
            return ClipSnapshot(items: [ClipItemSnapshot(representations: representations)])
        }
        let items = snapshots.flatMap(\.items)
        return items.isEmpty ? nil : ClipSnapshot(items: items)
    }
}
