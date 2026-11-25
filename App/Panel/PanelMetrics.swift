import AppKit

/// 主面板的样式数值，来自 Docs/归档/调研/08-本机核对结果.md 第 5.1 节的实测。只在这里改。
enum PanelMetrics {
    /// 默认高度；用户可在 minWindowHeight…maxWindowHeight 之间拖动上缘调整，双击上缘或从菜单恢复到它。
    /// 原版实测是 319（Docs/归档/调研/08 第 5.1 节），2026-11-24 用户决定改为 332（卡片边长 234）。
    static let windowHeight: CGFloat = 332
    /// 拖动时离默认高度这么近就吸到默认高度上。
    static let heightSnapDistance: CGFloat = 6
    static let minWindowHeight: CGFloat = 252
    static let maxWindowHeight: CGFloat = 412
    /// 高度低于这个值进入紧凑模式（实测 297 为紧凑、302 为标准）。
    static let compactThreshold: CGFloat = 300

    static func isCompact(windowHeight: CGFloat) -> Bool { windowHeight < compactThreshold }

    /// 卡片是正方形，边长随面板高度变化：332 → 234，319 → 221，252 → 152，412 → 314。
    static func cardSide(windowHeight: CGFloat) -> CGFloat {
        windowHeight - (isCompact(windowHeight: windowHeight) ? 100 : 98)
    }

    /// 来源图标随卡片缓慢放大：边长 221 → 78，254 → 82，304 → 86。
    static func appIconSize(forCardSide side: CGFloat) -> CGFloat {
        (78 + (side - 221) * 0.1).rounded()
    }

    static let compactHeaderHeight: CGFloat = 40
    static let compactAppIconSize: CGFloat = 22
    static let compactCardSpacing: CGFloat = 24
    /// 选中描边画在卡片外侧，紧贴卡片边缘，中间不留缝（原版如此）。等于 `selectionBorderWidth`。
    static let selectionOutset: CGFloat = 4
    /// 上缘可拖动调整高度的热区（从玻璃面板顶边向下）。
    static let resizeHandleHeight: CGFloat = 8
    /// 上缘热区左右各让出的宽度，避开两端的圆角。
    static let resizeHandleInset: CGFloat = 40
    /// 窗口左右和底边到可见玻璃面板的边距。顶边没有，玻璃顶到窗口上缘（原版如此）。
    static let outerMargin: CGFloat = 8
    static let panelCornerRadius: CGFloat = 28

    static let toolbarHeight: CGFloat = 60
    static let toolbarButtonSize: CGFloat = 34
    static let toolbarButtonTop: CGFloat = 13
    static let searchFieldWidth: CGFloat = 370

    /// 卡片区高度 = 面板高度 − 68（工具栏 60 + 底部边距 8）。
    static func cardAreaHeight(windowHeight: CGFloat) -> CGFloat { windowHeight - 68 }
    static let cardSpacing: CGFloat = 22
    /// 首卡左缘距卡片区左边。
    static let cardLeadingInset: CGFloat = 23
    static let cardTopInset: CGFloat = 8
    static let cardCornerRadius: CGFloat = 16
    static let cardPadding: CGFloat = 12
    static let cardHeaderHeight: CGFloat = 52
    static let cardFooterBottom: CGFloat = 10

    static let appIconSize: CGFloat = 78
    /// 来源图标向卡片右侧溢出的宽度，被卡片圆角裁掉。图标只画在标题栏里，超出标题栏底边的部分也裁掉，
    /// 所以左下角只露出一点圆角，和标题栏底边齐平（原版如此，对原版截图逐像素量过）。
    static let appIconOverflow: CGFloat = 14

    static let selectionBorderWidth: CGFloat = 4
    // 出入场动画按原版录屏逐帧量得（Docs/归档/调研/08 第 9.6 节）：
    // 出现是从屏幕底边以下整体滑入，约 120 ms，每帧剩余距离减半；消失是向下滑出，约 150 ms，先慢后快。都没有淡入淡出。
    static let showDuration: TimeInterval = 0.18
    static let hideDuration: TimeInterval = 0.15
    static var showTiming: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1) }
    static var hideTiming: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.7, 0, 0.84, 0) }
    /// 卡片正文、预览内容区和编辑窗口文本区的底色。原版深色是 #1A1A1A，比系统的 `textBackgroundColor`（#1E1E1E）深；浅色是白色（L06）。
    static let contentBackgroundColor = NSColor(name: "XPasteContentBackground") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(srgbRed: 0x1A / 255.0, green: 0x1A / 255.0, blue: 0x1A / 255.0, alpha: 1) : .white
    }
    // 预览浮层（Docs/归档/调研/08 第 5.4 节）。尺寸是浮层可见部分，不含系统加的阴影边距和箭头。
    static let previewTextSize = NSSize(width: 390, height: 316)
    static let previewColorSize = NSSize(width: 460, height: 369)
    static let previewHeaderHeight: CGFloat = 38
    static let previewFooterHeight: CGFloat = 38
    /// 内容区到浮层左右边缘的距离。
    static let previewContentInset: CGFloat = 5
    static let previewContentCornerRadius: CGFloat = 5
    static let previewMinContentSize = NSSize(width: 380, height: 240)
    /// 文本预览量尺寸时只取开头这么多 UTF-16 码元（原版 6.6.2 二进制核对，用户 2026-11-24）；正文仍可滚动看全。
    static let previewTextMeasureLimit = 2_000
    /// 文本视图的内边距：左右各 8.5 加行片段自带的 5，上下各 10.5（见 `PreviewViewController` 的 `textContainerInset`）。
    static let previewTextInsets = NSSize(width: (8.5 + 5) * 2, height: 10.5 * 2)

    /// 文本预览的内容区尺寸（原版 6.6.2 的做法）：用 `boundingRect` 量开头一段的排版尺寸，所以最长的一行、换行和富文本字号都算数；
    /// 加上文字内边距后，最小 380 × 240，宽、高最大各为屏幕的一半。短文本浮层 390 × 316，
    /// 长文本在 1800 × 1169 的屏幕上撑满约 910 × 661。
    static func previewTextContentSize(_ text: NSAttributedString, screenSize: NSSize) -> NSSize {
        let limit = NSSize(width: (screenSize.width / 2).rounded(.down), height: screenSize.height / 2)
        let sample = text.length > previewTextMeasureLimit
            ? text.attributedSubstring(from: NSRange(location: 0, length: previewTextMeasureLimit)) : text
        let measured = sample.boundingRect(with: NSSize(width: limit.width - previewTextInsets.width, height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading])
        let width = ceil(measured.width) + previewTextInsets.width
        let height = ceil(measured.height) + previewTextInsets.height
        return NSSize(width: min(max(width, previewMinContentSize.width), limit.width),
                      height: min(max(height, previewMinContentSize.height), limit.height))
    }

    /// 浮层可见尺寸 = 内容区 + 顶栏、底栏和左右内缩，向上取整到整点（原版的五组 AX frame 都符合，L10）。
    static func previewSize(forContent content: NSSize) -> NSSize {
        NSSize(width: (content.width + previewContentInset * 2).rounded(.up),
               height: (content.height + previewHeaderHeight + previewFooterHeight).rounded(.up))
    }

    /// 图片预览的内容区尺寸（Docs/归档/调研/08 第 9.12 节）：一个像素按一个点算，只缩小不放大；
    /// 最大是屏幕的一半，最小与文本预览相同。保留小数，取整留给 `previewSize(forContent:)`。
    static func previewImageContentSize(pixelSize: NSSize, screenSize: NSSize) -> NSSize {
        let limit = NSSize(width: screenSize.width / 2, height: screenSize.height / 2)
        let scale = previewImageScale(pixelSize: pixelSize, fitting: limit)
        return NSSize(width: min(max(pixelSize.width * scale, previewMinContentSize.width), limit.width),
                      height: min(max(pixelSize.height * scale, previewMinContentSize.height), limit.height))
    }

    /// 底栏右侧有按钮（在浏览器中打开、在 Finder 中显示）时的高度；左侧文字折成两行时更高。
    static let previewButtonFooterHeight: CGFloat = 45
    static let previewTwoLineFooterHeight: CGFloat = 55

    /// 链接和文件预览的浮层尺寸（Docs/归档/调研/08 第 9.13 节）：固定为图片预览的最大尺寸，在 1800 × 1169 的屏幕上是 910 × 661。
    static func previewLargeSize(screenSize: NSSize) -> NSSize {
        NSSize(width: (screenSize.width / 2).rounded(.down) + previewContentInset * 2,
               height: (screenSize.height / 2 + previewHeaderHeight + previewFooterHeight).rounded(.up))
    }

    static func previewImageScale(pixelSize: NSSize, fitting box: NSSize) -> CGFloat {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return 1 }
        return min(1, box.width / pixelSize.width, box.height / pixelSize.height)
    }

    /// 拖动卡片时跟着鼠标走的图略微透明；离开卡片区（拖到工具栏一带）后缩到约六成（Docs/归档/调研/08 第 9.17、9.25 节）。
    static let dragImageScale: CGFloat = 0.58
    static let dragImageOpacity: CGFloat = 0.85

    /// 面板可见时相对时间的刷新间隔。
    static let timeRefreshInterval: TimeInterval = 30
}

/// 系统“辅助功能 → 显示”里影响面板画法的选项。
/// Debug 构建可以用环境变量模拟（`XPASTE_INCREASE_CONTRAST=1`），验收时不用改系统设置；最终仍要在真实设置下看一遍。
@MainActor
enum DisplayOptions {
    static var increaseContrast: Bool {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["XPASTE_INCREASE_CONTRAST"] { return value == "1" }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }
}
