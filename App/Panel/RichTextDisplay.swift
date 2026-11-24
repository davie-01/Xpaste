import AppKit

/// 卡片和预览显示条目自带的富文本（原版两处都按富文本显示，L05、L98）。
enum RichTextDisplay {
    /// 没有字体的片段补上 `font`；没有颜色、或是接近纯黑纯白的中性色，换成跟随外观的文字色。
    /// 网页和文稿复制来的 RTF 常写死黑色，不换的话在深色卡片上看不见；有色相的颜色原样保留。
    static func prepare(_ attributed: NSAttributedString, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: attributed)
        result.enumerateAttributes(in: NSRange(location: 0, length: result.length)) { attributes, range, _ in
            if attributes[.font] == nil { result.addAttribute(.font, value: font, range: range) }
            let color = attributes[.foregroundColor] as? NSColor
            if color.map(isNeutralExtreme) ?? true { result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range) }
        }
        return result
    }

    private static func isNeutralExtreme(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        guard let low = channels.min(), let high = channels.max(), high - low < 0.08 else { return false }
        return high < 0.25 || low > 0.85
    }
}
