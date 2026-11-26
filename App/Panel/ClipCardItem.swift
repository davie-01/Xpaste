import AppKit
import ClipboardKit
import PasteCore

/// 一张卡片。尺寸随面板高度变化，所有子视图的位置都在 `layoutCard()` 里按当前尺寸计算。
///
/// 根视图比卡片本体四周各大 `PanelMetrics.selectionOutset`，用来在卡片外侧画选中描边。
@MainActor
final class ClipCardItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ClipCardItem")

    private let card = NSView()
    private let header = NSView()
    private let kindLabel = NSTextField(labelWithString: "")
    private var timeHiddenBeforeEditing = false
    private var isEditingTitle = false { didSet { view.needsLayout = true } }
    private let timeLabel = NSTextField(labelWithString: "")
    private let appIcon = NSImageView()
    private let bodyLabel = CardBodyLabel(wrappingLabelWithString: "")
    private let bodyImage = NSImageView()
    /// 图片卡片正文区的棋盘格衬底。
    private let checkerboard = CardCheckerboardView()
    private let footerLabel = NSTextField(labelWithString: "")
    private let footerBadge = NSView()
    /// 链接卡片：页面标题在地址上方，页面配图铺满正文区上半部分。
    private let linkTitleLabel = NSTextField(labelWithString: "")
    private let linkCover = NSView()

    /// 卡片底色；颜色类型用色值本身，其余为 nil 表示跟随外观。
    private var fillColor: NSColor?
    /// 带富文本的文本卡片：整块正文的底色和文字外观随它（原版的规则，见 `RichTextDisplay.prepare`）。
    private var richBackdrop: RichTextDisplay.Prepared?
    private var kind: ClipKind = .text
    var isCompact = false { didSet { if isCompact != oldValue { view.needsLayout = true } } }

    /// VoiceOver 的操作：按下（粘贴）、显示菜单、其余常用操作。卡片会被复用，每次配置时由面板重新设置。
    var onAccessibilityPress: (() -> Void)?
    var accessibilityMenu: (() -> NSMenu?)?
    var accessibilityActions: (() -> [NSAccessibilityCustomAction])?
    private var accessibilityName = ""
    /// 这张卡片现在显示的是哪一条。批量删除后核对卡片有没有跟着挪对位置（见 `PanelController.updateRemovals`）。
    private(set) var clipID: ClipSummary.ID?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerCurve = .continuous

        card.wantsLayer = true
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        header.wantsLayer = true
        header.layer?.masksToBounds = true

        kindLabel.lineBreakMode = .byTruncatingTail
        appIcon.imageScaling = .scaleProportionallyUpOrDown

        bodyLabel.textColor = .labelColor
        // 换行标签默认可选中文字，会抢走点击并弹出系统的文本菜单；卡片上的文字只用于展示。
        bodyLabel.isSelectable = false
        bodyLabel.wantsLayer = true
        bodyImage.imageScaling = .scaleProportionallyDown

        footerBadge.wantsLayer = true
        footerBadge.layer?.cornerRadius = 6
        footerLabel.font = .systemFont(ofSize: 12)
        footerLabel.alignment = .center
        footerLabel.lineBreakMode = .byTruncatingMiddle

        linkTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        linkTitleLabel.textColor = .labelColor
        linkTitleLabel.lineBreakMode = .byTruncatingTail
        linkCover.wantsLayer = true
        linkCover.layer?.contentsGravity = .resizeAspectFill
        linkCover.layer?.masksToBounds = true

        for sub in [checkerboard, linkCover, bodyImage, bodyLabel, footerBadge, footerLabel, linkTitleLabel, header, kindLabel, timeLabel] { card.addSubview(sub) }
        header.addSubview(appIcon)
        root.addSubview(card)
        view = root
    }

    // MARK: 辅助功能

    // 集合视图把每个 item 当作一个辅助功能元素（角色是组），卡片视图是它唯一的子元素。
    // 这里让整张卡片在 VoiceOver 里只是一个元素，里面的文字和图标不单独出现，免得一张卡片要停五六次。
    // NSCollectionViewItem 的辅助功能方法是 AppKit 私下实现的，Swift 里看不到，只能用同名的 @objc 方法在运行时覆盖。
    @objc func accessibilityLabel() -> String? { accessibilityName }
    @objc func accessibilityRoleDescription() -> String? { String(localized: "剪贴板条目") }
    @objc func accessibilityChildren() -> [Any]? { [] }
    @objc func isAccessibilitySelected() -> Bool { isSelected }
    @objc func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? { accessibilityActions?() }

    @objc func accessibilityPerformPress() -> Bool {
        guard let onAccessibilityPress else { return false }
        onAccessibilityPress()
        return true
    }

    @objc func accessibilityPerformShowMenu() -> Bool { showAccessibilityMenu() }

    private func showAccessibilityMenu() -> Bool {
        guard let menu = accessibilityMenu?() else { return false }
        #if DEBUG
        // 验收时菜单弹出后不靠按键关闭（XPASTE_MENU_AUTOCLOSE=秒数）：发 Esc 有可能落到别的应用。
        if let seconds = ProcessInfo.processInfo.environment["XPASTE_MENU_AUTOCLOSE"].flatMap(Double.init) {
            let timer = Timer(timeInterval: seconds, repeats: false) { _ in menu.cancelTracking() }
            RunLoop.main.add(timer, forMode: .eventTracking)
        }
        #endif
        // 从卡片上部弹出：卡片贴着屏幕底边，从中间弹的话菜单下半截要滚动才看得到。
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.midX, y: view.bounds.maxY - 24), in: view)
        return true
    }

    /// 拖动时跟着鼠标走的图：原尺寸、略微透明。拖到卡片区上方时由面板缩小（L37）。
    override var draggingImageComponents: [NSDraggingImageComponent] {
        let scale: CGFloat = 1
        let size = NSSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return super.draggingImageComponents }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let source = rep.cgImage,
              let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return super.draggingImageComponents }
        context.setAlpha(PanelMetrics.dragImageOpacity)
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        guard let image = context.makeImage() else { return super.draggingImageComponents }
        let component = NSDraggingImageComponent(key: .icon)
        component.contents = image
        component.frame = NSRect(x: (view.bounds.width - size.width) / 2, y: (view.bounds.height - size.height) / 2, width: size.width, height: size.height)
        return [component]
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.borderWidth = isSelected ? PanelMetrics.selectionBorderWidth : 0
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutCard()
        applyTextAppearance()
        // 动态颜色需要在当前外观下解析。
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let backdrop = richBackdrop?.backdrop(for: view.effectiveAppearance)
            card.layer?.backgroundColor = (backdrop ?? fillColor ?? PanelMetrics.contentBackgroundColor).cgColor
            card.layer?.borderColor = NSColor.separatorColor.cgColor
            // 重命名期间选中框是灰色（原版如此）。
            view.layer?.borderColor = (isEditingTitle ? NSColor.systemGray : NSColor.controlAccentColor).cgColor
            // 图片尺寸的小标签：深色是半透明黑底白字，浅色是浅灰底灰字（原版截图取的 #EAEBEA、#868686）。
            footerBadge.layer?.backgroundColor = (isDark ? NSColor.black.withAlphaComponent(0.45) : NSColor(white: 0xEA / 255.0, alpha: 1)).cgColor
        }
    }

    /// 正文区的文字（正文和字符数）按整块底色的深浅选外观；系统外观切换时卡片会重新布局，这里跟着换。
    private func applyTextAppearance() {
        let appearance = richBackdrop?.textAppearance(for: view.effectiveAppearance)
        bodyLabel.appearance = appearance
        footerLabel.appearance = appearance
    }

    private var isDark: Bool { view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    private func layoutCard() {
        let m = PanelMetrics.self
        let outset = m.selectionOutset
        card.frame = view.bounds.insetBy(dx: outset, dy: outset)
        card.layer?.cornerRadius = m.cardCornerRadius
        view.layer?.cornerRadius = m.cardCornerRadius + outset

        let side = card.bounds.width
        let height = card.bounds.height
        let pad = m.cardPadding
        let headerHeight = isCompact ? m.compactHeaderHeight : m.cardHeaderHeight
        header.frame = NSRect(x: 0, y: height - headerHeight, width: side, height: headerHeight)

        if isCompact {
            // 紧凑模式：标题栏单行“类型 时间”，来源图标缩成小图标放在右上角。
            let icon = m.compactAppIconSize
            kindLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            timeLabel.font = .systemFont(ofSize: 13)
            kindLabel.sizeToFit()
            let kindWidth = min(kindLabel.frame.width, side - pad * 2 - (appIcon.isHidden ? 0 : icon) - 40)
            let lineY = height - headerHeight + (headerHeight - 18) / 2
            kindLabel.frame = NSRect(x: pad, y: lineY, width: kindWidth, height: 18)
            timeLabel.frame = NSRect(x: pad + kindWidth + 6, y: lineY, width: max(0, side - pad * 2 - kindWidth - 6 - icon - 4), height: 18)
            appIcon.frame = NSRect(x: side - pad - icon + 2, y: (headerHeight - icon) / 2, width: icon, height: icon)
        } else {
            // 来源图标随卡片略微放大，向右、向上溢出的部分被卡片圆角裁掉。
            let icon = m.appIconSize(forCardSide: side)
            kindLabel.font = .systemFont(ofSize: 15, weight: .semibold)
            timeLabel.font = .systemFont(ofSize: 12)
            let textWidth = appIcon.isHidden ? side - pad * 2 : side - pad - (icon - m.appIconOverflow) - 4
            // 纵向位置与原版的辅助功能坐标对过：两行文字的中心线一致。没有时间（Pinboard 里）时名称在标题栏里居中。
            let kindY = timeLabel.isHidden ? height - headerHeight + (headerHeight - 21) / 2 : height - 6 - 21
            kindLabel.frame = NSRect(x: pad, y: kindY, width: textWidth, height: 21)
            timeLabel.frame = NSRect(x: pad, y: height - 24 - 17, width: textWidth, height: 17)
            // 图标在标题栏里，坐标相对标题栏，上下都超出标题栏 8、被裁掉，左上角和左下角都只露出一点圆角（原版如此，对原版截图量过）。
            // 图标图片四周有 100/1024 的留白；画得比 `icon` 大一些才够上下各超出 8，露出来的宽度不变。
            let margin = 100.0 / 1024
            let drawn = ((headerHeight + 16) / (1 - margin * 2)).rounded()
            let visible = icon - m.appIconOverflow - icon * margin
            appIcon.frame = NSRect(x: side - visible - drawn * margin, y: -8 - drawn * margin, width: drawn, height: drawn)
        }

        let areaHeight = height - headerHeight
        // 紧凑模式不显示字符数这类底栏说明；链接的地址和图片的尺寸仍然保留。
        let showsFooter = !footerLabel.stringValue.isEmpty && !(isCompact && (kind == .text || kind == .unknown))
        footerLabel.isHidden = !showsFooter
        footerBadge.isHidden = !(showsFooter && kind == .image)
        footerLabel.textColor = kind == .image ? (isDark ? .white : NSColor(white: 0x86 / 255.0, alpha: 1)) : .secondaryLabelColor

        if kind == .image {
            // 图片尺寸放在半透明小标签里，压在图片底部居中。
            footerLabel.sizeToFit()
            let width = min(footerLabel.frame.width + 12, side - pad * 2)
            footerBadge.frame = NSRect(x: (side - width) / 2, y: m.cardFooterBottom - 2, width: width, height: 21)
            footerLabel.frame = footerBadge.frame.insetBy(dx: 6, dy: 2)
        } else if kind == .file {
            // 路径最多两行（Docs/归档/调研/08 第 5.3 节，L17）。
            footerLabel.frame = NSRect(x: pad, y: m.cardFooterBottom, width: side - pad * 2, height: 32)
        } else {
            footerLabel.frame = NSRect(x: pad, y: m.cardFooterBottom, width: side - pad * 2, height: 17)
        }

        let footerSpace: CGFloat = showsFooter && kind != .image ? (kind == .file ? 50 : 36) : pad
        checkerboard.isHidden = kind != .image
        checkerboard.frame = NSRect(x: 0, y: 0, width: side, height: areaHeight)
        switch kind {
        case .image:
            bodyImage.frame = NSRect(x: 0, y: 0, width: side, height: areaHeight)
        case .link:
            // 按原版截图量的：标题紧贴在地址上面；图标 34（占位的指南针 36），在标题栏和文字之间居中略偏上。
            let textTop = linkTitleLabel.isHidden ? (showsFooter ? m.cardFooterBottom + 17 : pad) : m.cardFooterBottom + 37
            linkTitleLabel.frame = NSRect(x: pad, y: m.cardFooterBottom + 19, width: side - pad * 2, height: 18)
            linkCover.frame = NSRect(x: 0, y: textTop + 9, width: side, height: max(0, areaHeight - textTop - 9))
            let icon: CGFloat = min(bodyImage.contentTintColor == nil ? 34 : 36, max(0, areaHeight - textTop - 12))
            bodyImage.frame = NSRect(x: (side - icon) / 2, y: textTop + (areaHeight - textTop - icon) / 2 + 4, width: icon, height: icon)
        case .file:
            bodyImage.frame = NSRect(x: 0, y: footerSpace, width: side, height: areaHeight - footerSpace).insetBy(dx: side * 0.3, dy: (areaHeight - footerSpace) * 0.22)
        case .color:
            bodyLabel.frame = NSRect(x: pad, y: (areaHeight - 24) / 2, width: side - pad * 2, height: 24)
        case .text, .unknown:
            let top = areaHeight - (isCompact ? 8 : 6)
            bodyLabel.frame = NSRect(x: pad, y: footerSpace, width: side - pad * 2, height: max(0, top - footerSpace))
        }
        layoutBodyOverflow()
    }

    /// 正文渐隐的高度（从 Paste 卡片截图估的，待真机核对）。
    static let bodyFadeHeight: CGFloat = 24
    private let bodyFade = CAGradientLayer()

    /// 文本卡片超出部分照原版渐隐（调研 08：文本卡片“超出渐隐”）：只画放得下的整行，正文区底部一段渐隐。
    /// 不再做末行省略号截断：`NSTextField` 截断含图片附件的行时会把图片画坏（画成两倍宽，应用里是一块白框）。
    /// 颜色卡片仍是单行居中、放不下时截断。
    private func layoutBodyOverflow() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard kind == .text || kind == .unknown else {
            bodyLabel.lineBreakMode = .byTruncatingTail
            bodyLabel.cell?.truncatesLastVisibleLine = true
            bodyLabel.maximumNumberOfLines = 1
            bodyLabel.layer?.mask = nil
            return
        }
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.cell?.truncatesLastVisibleLine = false
        bodyLabel.maximumNumberOfLines = 0
        let height = max(1, bodyLabel.bounds.height)
        let fade = min(1, Self.bodyFadeHeight / height)
        bodyFade.frame = bodyLabel.bounds
        bodyFade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        bodyFade.locations = [0, NSNumber(value: Double(fade)), 1]
        // 渐变的单位坐标跟着图层的几何方向走：图层上下翻转时 y = 0 在上边。
        let flipped = bodyLabel.layer?.isGeometryFlipped ?? false
        bodyFade.startPoint = CGPoint(x: 0.5, y: flipped ? 1 : 0)
        bodyFade.endPoint = CGPoint(x: 0.5, y: flipped ? 0 : 1)
        bodyLabel.layer?.mask = bodyFade
    }

    /// `pinboardColor`：条目固定在某个 Pinboard 时那个 Pinboard 的颜色；`inPinboard`：正在看的是 Pinboard 而不是历史。
    /// 只更新相对时间（审查 14）：定时刷新不再整表重查、重配卡片。
    func refreshTime(for clip: ClipSummary, now: Date) {
        timeLabel.stringValue = Self.relativeTime(from: clip.timestamp ?? clip.createdAt, to: now, short: isCompact)
        accessibilityName = Self.accessibilityLabel(for: clip, now: now)
    }

    func configure(with clip: ClipSummary, now: Date, compact: Bool, pinboardColor: NSColor? = nil, inPinboard: Bool = false) {
        clipID = clip.id
        kind = clip.kind
        isCompact = compact
        kindLabel.stringValue = clip.title ?? Self.typeTitle(for: clip)
        let date = clip.timestamp ?? clip.createdAt
        timeLabel.stringValue = Self.relativeTime(from: date, to: now, short: compact)
        // 原版悬停在时间上显示具体日期和时刻。
        timeLabel.toolTip = Self.fullDateFormatter.string(from: date)
        // 原版在 Pinboard 里只显示名称，没有时间（M5 第 6 步实测）。
        timeLabel.isHidden = inPinboard

        // 固定过的条目，标题栏用 Pinboard 的颜色，在历史里也是这样（M5 第 6 步实测）；来源图标照常显示（原版不显示，这里有意保留）。
        let source = AppAppearanceCache.shared.appearance(for: clip.sourceBundleID, storedColorHex: clip.sourceColorHex)
        appIcon.image = source.icon
        appIcon.isHidden = false
        let headerColor = pinboardColor ?? source.color
        header.layer?.backgroundColor = headerColor.cgColor
        // 增强对比度：卡片加一圈描边和玻璃背景分开；标题栏底色浅时文字改黑色，时间不再半透明。
        let increaseContrast = DisplayOptions.increaseContrast
        card.layer?.borderWidth = increaseContrast ? 1 : 0
        let headerText: NSColor = increaseContrast && headerColor.isLight ? .black : .white
        kindLabel.textColor = headerText
        timeLabel.textColor = increaseContrast ? headerText : headerText.withAlphaComponent(0.85)

        bodyImage.isHidden = true
        bodyImage.contentTintColor = nil
        bodyLabel.isHidden = false
        bodyLabel.alignment = .left
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.textColor = .labelColor
        fillColor = nil
        richBackdrop = nil
        bodyLabel.vibrancyAllowed = true
        footerLabel.alignment = .center
        footerLabel.lineBreakMode = .byTruncatingMiddle
        footerLabel.cell?.wraps = false
        footerLabel.maximumNumberOfLines = 1
        footerLabel.toolTip = nil
        linkTitleLabel.isHidden = true
        linkCover.isHidden = true
        linkCover.layer?.contents = nil

        switch clip.kind {
        case .image:
            bodyLabel.isHidden = true
            bodyImage.isHidden = false
            bodyImage.imageScaling = .scaleProportionallyUpOrDown
            bodyImage.image = ThumbnailCache.shared.image(for: clip)
            if let width = clip.pixelWidth, let height = clip.pixelHeight {
                footerLabel.stringValue = "\(width) × \(height)"
            } else {
                footerLabel.stringValue = ""
            }
        case .file:
            let paths = clip.filePaths
            bodyLabel.isHidden = true
            bodyImage.isHidden = false
            bodyImage.imageScaling = .scaleProportionallyUpOrDown
            // 图片文件复制时存了缩略图，就显示它（原版如此，L112）；其余显示文件图标。
            bodyImage.image = (paths.count == 1 ? ThumbnailCache.shared.image(for: clip) : nil) ?? paths.first.map { NSWorkspace.shared.icon(forFile: $0) }
            // 原版底部是完整路径：超过 108 个字符时只留最后 108 个、前面加“…”，放进两行，放不下的部分直接截掉；悬停显示全路径
            // （M5 第 6 步从原版的辅助功能值读出来的）。
            let path = paths.first ?? ""
            footerLabel.stringValue = path.count > Self.pathLimit ? "…" + String(path.suffix(Self.pathLimit)) : path
            footerLabel.toolTip = path
            footerLabel.alignment = .left
            footerLabel.lineBreakMode = .byWordWrapping
            footerLabel.cell?.wraps = true
            footerLabel.maximumNumberOfLines = 2
        case .color:
            let text = clip.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
            let color = NSColor(hex: text) ?? .gray
            fillColor = color
            bodyLabel.stringValue = "#" + (text.hasPrefix("#") ? String(text.dropFirst()) : text).uppercased()
            bodyLabel.alignment = .center
            bodyLabel.font = .monospacedSystemFont(ofSize: 17, weight: .semibold)
            bodyLabel.textColor = color.isLight ? .black : .white
            footerLabel.stringValue = ""
        case .link:
            // 页面标题和配图来自链接预览，后台取到后补上；没有的时候显示占位图标，只有去掉协议头的地址。
            let text = clip.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
            bodyLabel.isHidden = true
            bodyImage.imageScaling = .scaleProportionallyUpOrDown
            let picture = clip.linkImage == .none ? nil : ThumbnailCache.shared.image(for: clip)
            if clip.linkImage == .image, let picture {
                bodyImage.isHidden = true
                linkCover.isHidden = false
                linkCover.layer?.contents = picture
            } else if let picture {
                bodyImage.isHidden = false
                bodyImage.image = picture
            } else {
                bodyImage.isHidden = false
                bodyImage.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
                bodyImage.contentTintColor = .tertiaryLabelColor
            }
            linkTitleLabel.stringValue = clip.linkTitle ?? ""
            linkTitleLabel.isHidden = clip.linkTitle == nil
            footerLabel.alignment = .left
            footerLabel.lineBreakMode = .byTruncatingTail
            footerLabel.stringValue = text.replacingOccurrences(of: #"^https?://(www\.)?"#, with: "", options: .regularExpression)
        case .text, .unknown:
            // 卡片只排版开头一小段，避免超长文本拖慢布局；字符数是全文的（UTF-16 码元；有富文本时按富文本，与原版一致）。
            // 带富文本的按富文本显示（原版如此，L98）。缓存可能是 RTF，也可能是带图片的 RTFD（开头有图片时）。
            // 图片不缩放、链接保留（原版卡片如此）：比正文区高的图片那一行放不下，就不画。
            if let data = clip.richPreview, let rich = RichText.decodePreview(data) {
                let prepared = RichTextDisplay.prepare(rich, font: .systemFont(ofSize: 13), keepsLinks: true)
                richBackdrop = prepared
                bodyLabel.vibrancyAllowed = false
                bodyLabel.attributedStringValue = prepared.text
            } else {
                bodyLabel.stringValue = String(clip.previewText.prefix(600))
            }
            footerLabel.stringValue = String(localized: "\(clip.charCount) 个字符")
        }
        accessibilityName = Self.accessibilityLabel(for: clip, now: now)
        view.needsLayout = true
    }

    /// 辅助功能里卡片的名称：名称（自定义名称时再加类型）、来源、时间，然后是内容。
    /// 时间总用完整写法，紧凑模式的“3分钟”读出来容易听错。
    static func accessibilityLabel(for clip: ClipSummary, now: Date) -> String {
        var parts = [clip.title ?? typeTitle(for: clip)]
        if clip.title != nil { parts.append(typeTitle(for: clip)) }
        if let source = clip.sourceName, !source.isEmpty { parts.append(source) }
        parts.append(relativeTime(from: clip.timestamp ?? clip.createdAt, to: now, short: false))
        let text = clip.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch clip.kind {
        case .image:
            if let width = clip.pixelWidth, let height = clip.pixelHeight { parts.append("\(width) × \(height)") }
        case .file:
            parts.append(clip.filePaths.map { ($0 as NSString).lastPathComponent }.joined(separator: String(localized: "、")))
        case .color:
            parts.append("#" + (text.hasPrefix("#") ? String(text.dropFirst()) : text).uppercased())
        case .link:
            if let title = clip.linkTitle, !title.isEmpty { parts.append(title) }
            parts.append(text)
        case .text, .unknown:
            // 只读开头一段，整段很长时 VoiceOver 要读很久；全文在预览里。
            parts.append(String(text.prefix(200)))
            parts.append(String(localized: "\(clip.charCount) 个字符"))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: String(localized: "，"))
    }

    /// 文件路径最多保留的字符数，与原版相同。
    private static let pathLimit = 108

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = appLocale
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()

    /// 没有自定义名称时显示的类型名，预览浮层的标题也用它。
    static func typeTitle(for clip: ClipSummary) -> String {
        switch clip.kind {
        case .text: String(localized: "文本")
        case .link: String(localized: "链接")
        case .image: String(localized: "图片")
        case .color: String(localized: "颜色")
        case .file: clip.filePaths.count > 1 ? String(localized: "\(clip.filePaths.count) 个文件") : String(localized: "1 个文件")
        case .unknown: String(localized: "未知")
        }
    }

    /// 时间文案跟随应用当前使用的界面语言，而不是系统的区域设置。
    private static let appLocale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "zh-Hans")

    private static let fullFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = appLocale
        return formatter
    }()

    /// 紧凑模式只写时长，不带“前”（“1分钟”“3 hr”）。
    private static let shortFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.minute, .hour, .day, .weekOfMonth, .month, .year]
        var calendar = Calendar.current
        calendar.locale = appLocale
        formatter.calendar = calendar
        return formatter
    }()

    private static func relativeTime(from date: Date, to now: Date, short: Bool) -> String {
        let elapsed = now.timeIntervalSince(date)
        guard elapsed >= 60 else { return String(localized: "现在") }
        if short { return shortFormatter.string(from: elapsed) ?? "" }
        return fullFormatter.localizedString(for: date, relativeTo: now)
    }

    /// 重命名：输入框放在标题的位置，用同样的字体和颜色；编辑期间隐藏标题（原版如此，用户真机：原来标题露在输入框后面）。
    /// 紧凑模式下时间和标题在同一行，一起让出来。返回的位置在 `view` 的坐标里。
    func beginTitleEditing(in view: NSView) -> (frame: NSRect, font: NSFont?, color: NSColor?) {
        var frame = kindLabel.frame
        timeHiddenBeforeEditing = timeLabel.isHidden
        if isCompact {
            frame.size.width = max(frame.width, timeLabel.frame.maxX - frame.minX)
            timeLabel.isHidden = true
        }
        kindLabel.isHidden = true
        isEditingTitle = true
        return (kindLabel.superview?.convert(frame, to: view) ?? frame, kindLabel.font, kindLabel.textColor)
    }

    func endTitleEditing() {
        isEditingTitle = false
        kindLabel.isHidden = false
        timeLabel.isHidden = timeHiddenBeforeEditing
    }
}

/// 图片卡片的衬底：8 pt 的深浅方格，等比缩放留出的边和图片的透明区域都显示它（Docs/归档/调研/08 第 5.3 节，L18）。预览里的是半透明的，见 `CheckerboardView`。
/// 两种颜色都是从原版截图里取的：深色 #282828 / #363636，浅色 #FFFFFF / #F4F4F4。
/// 卡片正文。富文本卡片要关掉活力效果：面板在玻璃里，允许活力效果时系统按活力混合画整个标签，
/// 深色卡片上的图片附件会被画成一块纯白（在玻璃窗口里实测复现，关掉后颜色正常）。纯文本卡片照旧。
final class CardBodyLabel: NSTextField {
    var vibrancyAllowed = true {
        didSet { if vibrancyAllowed != oldValue { needsDisplay = true } }
    }
    override var allowsVibrancy: Bool { vibrancyAllowed && super.allowsVibrancy }
}

final class CardCheckerboardView: NSView {
    private static let square: CGFloat = 8

    override var isFlipped: Bool { true }

    /// 深浅两套 2 × 2 格的图案，各画一次后复用：绘制时一次填满需要重画的区域，不再逐格填（轻量化）。
    private static let patterns: (dark: NSColor, light: NSColor) = (pattern(dark: true), pattern(dark: false))

    private static func pattern(dark: Bool) -> NSColor {
        let side = square * 2
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            NSColor(white: dark ? 0x28 / 255.0 : 1, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: side, height: side).fill()
            NSColor(white: dark ? 0x36 / 255.0 : 0xF4 / 255.0, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: square, height: square).fill()
            NSRect(x: square, y: square, width: square, height: square).fill()
            return true
        }
        return NSColor(patternImage: image)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // 图案按窗口坐标平铺，把起点对到这个视图的左上角，方格从卡片的角开始。
        NSGraphicsContext.current?.patternPhase = convert(NSPoint(x: 0, y: 0), to: nil)
        (dark ? Self.patterns.dark : Self.patterns.light).setFill()
        dirtyRect.fill()
    }
}

/// 解码后的缩略图缓存，按占用的像素字节数限额。
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache: NSCache<NSNumber, NSImage> = {
        let cache = NSCache<NSNumber, NSImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    func image(for clip: ClipSummary) -> NSImage? {
        let key = NSNumber(value: clip.id)
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = clip.thumbnail, let image = NSImage(data: data) else { return nil }
        let pixels = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? 0
        cache.setObject(image, forKey: key, cost: pixels * 4)
        return image
    }

    /// 条目的缩略图换了（编辑过图片、链接的配图取回来了）之后调用。
    func remove(id: ClipSummary.ID) { cache.removeObject(forKey: NSNumber(value: id)) }

    func removeAll() { cache.removeAllObjects() }
}

/// 来源应用的图标与标题栏主色，按 bundle ID 缓存。
/// 颜色算出来后经 `onColorComputed` 存进数据库，应用被卸载后仍能显示原来的颜色。
@MainActor
final class AppAppearanceCache {
    static let shared = AppAppearanceCache()

    struct Appearance {
        let icon: NSImage?
        let color: NSColor
    }

    var onColorComputed: ((_ bundleID: String, _ hex: String) -> Void)?
    /// 应用在本机时交出图标的 PNG 存库；应用不在了时从库里取回（L42）。
    var onIconAvailable: ((_ bundleID: String, _ png: Data) -> Void)?
    var storedIcon: ((_ bundleID: String) -> Data?)?

    private var cache: [String: Appearance] = [:]
    private let fallbackColor = NSColor(white: 0.35, alpha: 1)
    private let genericIcon = NSWorkspace.shared.icon(for: .application)

    func appearance(for bundleID: String?, storedColorHex: String? = nil) -> Appearance {
        guard let bundleID else { return Appearance(icon: nil, color: fallbackColor) }
        if let cached = cache[bundleID] { return cached }

        let appearance: Appearance
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let systemIcon = NSWorkspace.shared.icon(forFile: url.path)
            let color = systemIcon.dominantColor
            // 只留一张显示用的位图（最大显示 78 点的两倍），不留系统图标对象和它按各种尺寸缓存的渲染结果（轻量化）。
            let icon = Self.rasterized(systemIcon, side: Self.cachedIconPixels)
            appearance = Appearance(icon: icon, color: color)
            if let hex = color.hexString, hex.caseInsensitiveCompare(storedColorHex ?? "") != .orderedSame {
                onColorComputed?(bundleID, hex)
            }
            if let onIconAvailable, let png = Self.png(of: icon, side: 128) { onIconAvailable(bundleID, png) }
        } else {
            // 应用已不在本机：用存下来的颜色和图标，没存过图标才用通用图标。
            let stored = storedIcon?(bundleID).flatMap { NSImage(data: $0) }
            appearance = Appearance(icon: stored ?? genericIcon, color: storedColorHex.flatMap { NSColor(hex: $0) } ?? fallbackColor)
        }
        cache[bundleID] = appearance
        return appearance
    }

    #if DEBUG
    func debugForget(_ bundleID: String) { cache[bundleID] = nil }
    #endif

    static let cachedIconPixels = Int(PanelMetrics.appIconSize * 2)

    /// 画成一张固定像素的位图，逻辑尺寸取像素的一半（2 倍屏清晰，1 倍屏系统会缩小）。
    static func rasterized(_ image: NSImage, side: Int) -> NSImage {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: side / 2, height: side / 2)
        let result = NSImage(size: rep.size)
        result.addRepresentation(rep)
        return result
    }

    static func png(of image: NSImage, side: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

extension NSImage {
    /// 来源应用标题栏的颜色：图标里出现次数最多的那个鲜艳颜色。
    ///
    /// 用原版数据库里 117 个应用的图标和它存的颜色校准过（L41、L118）：
    /// - 按**精确颜色**计数，不分组。分组会把几块面积相近的纯色块的抗锯齿边缘算进去，打平时挑哪块很偶然（Snipaste 原版绿、分组挑成红或黄）；
    ///   精确计数时大块纯色占优，和原版一致（Snipaste 绿、ClashX Meta 黄、Chrome 蓝）。
    /// - 只数饱和度 0.35 以上、不太暗的像素。黑底、白底、灰色都不算。
    /// - 这样的像素不到图标的 6% 时（文本编辑只有一条红线，计算器、终端同理）按 `neutralColor(…)` 取图标自己的灰（L96）。
    /// 按 sRGB 绘制。与原版的中位色差从 39 降到 29（RGB 欧氏距离），差得多（超过 60）的从 46 个降到 35 个。
    var dominantColor: NSColor {
        let side = 64
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Self.neutralColor }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return Self.neutralColor }
        var counts: [UInt32: Int] = [:]
        var opaque = 0, vivid = 0
        var sum = (r: 0, g: 0, b: 0)
        for i in 0..<(side * side) where data[i * 4 + 3] > 250 {
            opaque += 1
            let r = Int(data[i * 4]), g = Int(data[i * 4 + 1]), b = Int(data[i * 4 + 2])
            sum.r += r; sum.g += g; sum.b += b
            let high = max(r, g, b), low = min(r, g, b)
            // 饱和度（HSB）= (最大 − 最小) / 最大；亮度 = 最大 / 255。
            guard high > 38, Double(high - low) / Double(high) >= 0.35 else { continue }
            vivid += 1
            counts[UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b), default: 0] += 1
        }
        guard opaque > 0 else { return Self.neutralColor }
        guard Double(vivid) >= Double(opaque) * 0.06,
              let top = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) })?.key else {
            let n = Double(opaque) * 255
            return Self.neutralColor(averageRed: Double(sum.r) / n, green: Double(sum.g) / n, blue: Double(sum.b) / n)
        }
        return NSColor(srgbRed: Double(top >> 16 & 0xFF) / 255, green: Double(top >> 8 & 0xFF) / 255, blue: Double(top & 0xFF) / 255, alpha: 1)
    }

    /// 图标完全透明、画不出来时的中灰。
    private static let neutralColor = NSColor(srgbRed: 127 / 255, green: 127 / 255, blue: 127 / 255, alpha: 1)

    /// 没有鲜艳颜色的图标：用整个图标的平均色，让终端、文本编辑、计算器这类排在一起也分得开（L96）。
    /// - 亮度按比例压进 0.25–0.60（不是截断），图标越亮标题栏越亮，先后顺序保留；上限保证白色标题文字看得清。
    /// - 保留图标原有的色调，饱和度最多 0.30，仍是偏灰的颜色，不和彩色图标的应用混淆。
    static func neutralColor(averageRed red: Double, green: Double, blue: Double) -> NSColor {
        let average = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(colorSpace: .sRGB, hue: hue, saturation: min(saturation, 0.30), brightness: 0.25 + brightness * 0.35, alpha: 1)
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var hexString: String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int(round(rgb.redComponent * 255)), Int(round(rgb.greenComponent * 255)), Int(round(rgb.blueComponent * 255)))
    }

    var isLight: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return false }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent > 0.6
    }
}
