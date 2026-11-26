import AppKit

/// 卡片和预览显示条目自带的富文本（原版两处都按富文本显示，L05、L98）。
enum RichTextDisplay {
    /// 准备好的显示副本和整块正文的底色。
    struct Prepared {
        let text: NSAttributedString
        /// 浅色、深色外观下各自的整块底色（不透明）。没有写前景色的片段跟随外观，两种外观下的统计结果可能不同。
        let lightBackdrop: NSColor
        let darkBackdrop: NSColor

        func backdrop(for appearance: NSAppearance) -> NSColor {
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkBackdrop : lightBackdrop
        }

        /// 按底色深浅选的外观：没有写前景色的文字用 `labelColor`，在这个外观下解析，才能和底色对比。
        func textAppearance(for appearance: NSAppearance) -> NSAppearance? {
            NSAppearance(named: RichTextDisplay.isLight(backdrop(for: appearance)) ? .aqua : .darkAqua)
        }
    }

    /// 按原版的整块底色规则准备富文本：
    /// 1. 分别统计前景色和背景色各覆盖多少 UTF-16 长度，同色多段合并；没写前景色的按外观的黑或白算。
    /// 2. 覆盖最多的前景色是亮色（(299R + 587G + 114B) / 1000 > 0.55）时，没有背景的范围记作 #1E1E1E，否则记作白色。
    /// 3. 原有背景和补出的背景里覆盖最多的颜色就是整块底色。
    /// 文字自带的前景色、局部背景和图片附件原样保留（图片不缩放，原版如此）；没有字体的片段补上 `font`。
    /// `keepsLinks`：卡片保留链接，`NSTextField` 把它画成蓝色、不加下划线（原版卡片如此）；
    /// 预览去掉链接，按网页原本的字色显示（原版预览如此，蓝底白字的“登录”不会变成蓝底蓝字）。只改显示副本。
    /// `maxAttachmentWidth`：比它宽的图片按比例缩到这个宽度。只有预览传（XPaste 的增强，原版按原尺寸排、超出文字区的部分裁掉）。
    static func prepare(_ attributed: NSAttributedString, font: NSFont, keepsLinks: Bool, maxAttachmentWidth: CGFloat? = nil) -> Prepared {
        let result = NSMutableAttributedString(attributedString: attributed)
        let whole = NSRange(location: 0, length: result.length)
        if !keepsLinks { result.removeAttribute(.link, range: whole) }
        result.enumerateAttributes(in: whole) { attributes, range, _ in
            if attributes[.font] == nil { result.addAttribute(.font, value: font, range: range) }
            if attributes[.foregroundColor] == nil { result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range) }
            if let maxAttachmentWidth, let attachment = attributes[.attachment] as? NSTextAttachment,
               let scaled = fitted(attachment, maxWidth: maxAttachmentWidth) {
                result.addAttribute(.attachment, value: scaled, range: range)
            }
        }
        return Prepared(text: result,
                        lightBackdrop: backdrop(of: attributed, defaultForeground: .black),
                        darkBackdrop: backdrop(of: attributed, defaultForeground: .white))
    }

    /// 空格预览用的富文本模型：复制段落样式并清空 `textBlocks`（网页里的表格布局），其余段落属性、文字样式和图片不变。
    /// 原版 6.6.9 生成预览模型时这样做（用户核对主程序，2026-11-26）；留着表格布局量尺寸，表格段落会把宽度撑到半屏。
    static func clearingTextBlocks(_ attributed: NSAttributedString) -> NSAttributedString {
        var blocked: [(NSRange, NSParagraphStyle)] = []
        attributed.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty { blocked.append((range, style)) }
        }
        guard !blocked.isEmpty else { return attributed }
        let result = NSMutableAttributedString(attributedString: attributed)
        for (range, style) in blocked {
            let copy = style.mutableCopy() as! NSMutableParagraphStyle
            copy.textBlocks = []
            result.addAttribute(.paragraphStyle, value: copy, range: range)
        }
        return result
    }

    /// 补出的底色：主导前景是亮色时用 #1E1E1E，暗色时用白色。
    static let darkFill = NSColor(deviceRed: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x1E / 255.0, alpha: 1)
    static let lightFill = NSColor(deviceWhite: 1, alpha: 1)

    static func backdrop(of text: NSAttributedString, defaultForeground: NSColor) -> NSColor {
        let whole = NSRange(location: 0, length: text.length)
        var foregrounds = Tally()
        var backgrounds = Tally()
        var uncovered = 0
        text.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            foregrounds.add((value as? NSColor) ?? defaultForeground, length: range.length)
        }
        text.enumerateAttribute(.backgroundColor, in: whole) { value, range, _ in
            if let color = value as? NSColor { backgrounds.add(color, length: range.length) } else { uncovered += range.length }
        }
        let fill = isLight(foregrounds.top ?? defaultForeground) ? darkFill : lightFill
        if uncovered > 0 { backgrounds.add(fill, length: uncovered) }
        return opaque(backgrounds.top ?? fill, over: fill)
    }

    /// 设备 RGB 下的亮度判定。
    static func isLight(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return false }
        return (299 * rgb.redComponent + 587 * rgb.greenComponent + 114 * rgb.blueComponent) / 1000 > 0.55
    }

    /// 半透明的底色叠在补出的底色上，卡片和文本视图都要不透明的颜色。
    private static func opaque(_ color: NSColor, over base: NSColor) -> NSColor {
        guard let top = color.usingColorSpace(.deviceRGB), let bottom = base.usingColorSpace(.deviceRGB) else { return base }
        let a = top.alphaComponent
        guard a < 1 else { return top }
        return NSColor(deviceRed: top.redComponent * a + bottom.redComponent * (1 - a),
                       green: top.greenComponent * a + bottom.greenComponent * (1 - a),
                       blue: top.blueComponent * a + bottom.blueComponent * (1 - a), alpha: 1)
    }

    /// 按颜色累计覆盖长度；颜色按设备 RGB 的 8 位分量合并，长度相同时先出现的优先。
    private struct Tally {
        private struct Key: Hashable { let r, g, b, a: Int }
        private var order: [Key] = []
        private var colors: [Key: NSColor] = [:]
        private var lengths: [Key: Int] = [:]

        mutating func add(_ color: NSColor, length: Int) {
            guard length > 0, let rgb = color.usingColorSpace(.deviceRGB) else { return }
            let key = Key(r: Int((rgb.redComponent * 255).rounded()), g: Int((rgb.greenComponent * 255).rounded()),
                          b: Int((rgb.blueComponent * 255).rounded()), a: Int((rgb.alphaComponent * 255).rounded()))
            if lengths[key] == nil { order.append(key); colors[key] = rgb }
            lengths[key, default: 0] += length
        }

        var top: NSColor? {
            var best: Key?
            for key in order where best == nil || lengths[key]! > lengths[best!]! { best = key }
            return best.flatMap { colors[$0] }
        }
    }

    /// 比 `maxWidth` 宽的图片附件换成按比例缩小的副本；不用缩的返回 nil。原附件不动。
    private static func fitted(_ attachment: NSTextAttachment, maxWidth: CGFloat) -> NSTextAttachment? {
        let size = attachment.attachmentCell?.cellSize() ?? attachment.image?.size ?? .zero
        guard maxWidth > 0, size.width > maxWidth, size.height > 0,
              let image = attachment.image ?? attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:))
        else { return nil }
        let fitted = NSSize(width: maxWidth.rounded(.down), height: (size.height * maxWidth / size.width).rounded())
        let resized = image.copy() as! NSImage
        resized.size = fitted
        let copy = NSTextAttachment()
        copy.image = resized
        copy.bounds = NSRect(origin: .zero, size: fitted)
        copy.attachmentCell = NSTextAttachmentCell(imageCell: resized)
        return copy
    }

    /// 行里只有一行文字，图片附件（来自 RTFD 缓存）去掉，和原来只存 RTF 时一样。
    static func adaptToAppearance(_ attributed: NSAttributedString, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: attributed)
        var attachments: [NSRange] = []
        result.enumerateAttribute(.attachment, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            if value != nil { attachments.append(range) }
        }
        for range in attachments.reversed() { result.deleteCharacters(in: range) }
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
