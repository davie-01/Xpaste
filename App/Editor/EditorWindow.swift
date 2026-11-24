import AppKit
import PasteCore

/// 编辑窗口里要编辑的东西。
enum EditorContent {
    /// 已有的文本条目。`isRich` 表示它原本带富文本表示。
    case text(NSAttributedString, isRich: Bool)
    case newText
    case link(String)
    /// `#RRGGBB`
    case color(String)
    case image(CGImage)
}

enum EditorResult {
    /// `rtf` 只在内容带格式时才有。
    case text(plain: String, rtf: Data?)
    case link(String)
    case color(String)
    /// PNG 数据。
    case image(Data)
}

/// 编辑窗口：和主面板一样不激活应用，自己成为 key 窗口接收键盘。
final class EditorPanel: ClipPanel {
    /// ⌘S、⌘B 这类快捷键。返回 true 表示已处理。
    var onKeyCommand: ((NSEvent) -> Bool)?
    var onCancel: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyCommand?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private final class EditorRootView: NSView {
    override var isFlipped: Bool { true }
}

/// 文本、链接、颜色的编辑与新建文本（Docs/08 第 5.5、9.14 节）。独立的浮动窗口，打开时主面板已收起。
@MainActor
final class EditorController: NSObject {
    private var window: EditorPanel?
    /// 保存时抛错（写库失败等）：窗口留着、内容不丢，底栏说明原因，可以再按保存（审查 15）。
    private var completion: ((EditorResult?) throws -> Void)?
    private var content: EditorContent = .newText

    private var textView: NSTextView?
    private let footerLabel = NSTextField(labelWithString: "")
    private var noticeTask: Task<Void, Never>?
    private let swatch = NSView()
    private let hexLabel = NSTextField(labelWithString: "")
    private var hex = ""
    /// 用户动过内容或格式。没动过就按取消处理，不改写条目。
    private var isDirty = false
    private var usedFormatting = false

    // 图片编辑：旋转和移除背景都从原图重新算，不在结果上叠加。
    private var originalImage: CGImage?
    /// 抠出主体后的原图；识别到主体才有。
    private var liftedImage: CGImage?
    /// 显示用的缩小版。旋转按钮只转它，整张原图的旋转和编码留到保存时在后台做（L28）。
    private var originalDisplay: CGImage?
    private var liftedDisplay: CGImage?
    nonisolated private static let displayMaxPixel = 2_048
    private var pendingSave: Task<Void, Never>?
    private var quarterTurns = 0
    private var backgroundRemoved = false
    private let imageView = NSImageView()
    private var backgroundButton: NSButton?
    /// B / I / U / S 按钮，按光标处已生效的格式显示状态（L22）。
    private var styleButtons: [(button: NSButton, style: TextStyle)] = []

    private enum TextStyle { case bold, italic, underline, strikethrough }
    private var liftTask: Task<Void, Never>?

    private static let defaultFont = NSFont.systemFont(ofSize: 13)

    var isOpen: Bool { window != nil }

    /// 打开编辑窗口。`completion` 的参数为 nil 表示取消或内容没有变化。
    /// 上一次图片保存还在进行时不打开新的，免得两次保存按完成顺序互相覆盖（审查 15）。
    func open(_ content: EditorContent, on screen: NSScreen?, completion: @escaping (EditorResult?) throws -> Void) {
        guard pendingSave == nil else { NSSound.beep(); return }
        if isOpen { finish(save: false) }
        self.content = content
        self.completion = completion
        isDirty = false
        usedFormatting = false

        let size: NSSize = switch content {
        case .newText: NSSize(width: 500, height: 360)
        case .link: NSSize(width: 390, height: 322)
        case .text, .color, .image: NSSize(width: 390, height: 316)
        }
        let panel = EditorPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.title = String(localized: "编辑")
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.onCancel = { [weak self] in self?.finish(save: false) }
        panel.onKeyCommand = { [weak self] in self?.handleCommand($0) ?? false }
        panel.contentView = buildContent(size: size)

        // 中心在屏幕高度 35% 处；新建窗口水平居中，编辑窗口比正中偏右 30（原版在两块屏上实测都如此）。不记位置，原版也不记（L23）。
        let area = (screen ?? NSScreen.main)?.frame ?? NSRect(x: 0, y: 0, width: 1800, height: 1169)
        let offset: CGFloat = if case .newText = content { 0 } else { 30 }
        panel.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2 + offset).rounded(), y: (area.maxY - area.height * 0.35 - size.height / 2).rounded()))
        WindowSharing.apply(to: panel)
        window = panel
        panel.makeKeyAndOrderFront(nil)
        if let textView {
            panel.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
            refreshStyleButtons()
        }
        if case .color = content { showColorPanel() }
    }

    // MARK: 搭建

    private func buildContent(size: NSSize) -> NSView {
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        let root = EditorRootView(frame: effect.bounds)
        root.autoresizingMask = [.width, .height]
        effect.addSubview(root)

        // 顶栏：取消在左，主按钮在右，各 48 × 24，距边 7。
        let cancel = pillButton(String(localized: "取消"), primary: false, action: #selector(cancelClicked))
        cancel.frame = NSRect(x: 7, y: 7, width: 48, height: 24)
        let isNew = if case .newText = content { true } else { false }
        let save = pillButton(isNew ? String(localized: "创建") : String(localized: "保存"), primary: true, action: #selector(saveClicked))
        save.frame = NSRect(x: size.width - 7 - 48, y: 7, width: 48, height: 24)
        root.addSubview(cancel)
        root.addSubview(save)

        let footerHeight: CGFloat = if case .link = content { 44 } else { 38 }
        let body = NSRect(x: 5, y: 38, width: size.width - 10, height: size.height - 38 - footerHeight)
        footerLabel.lineBreakMode = .byTruncatingTail
        footerLabel.frame = NSRect(x: 11, y: body.maxY + (footerHeight == 44 ? 13 : 10), width: size.width - 22, height: 18)
        root.addSubview(footerLabel)
        textView = nil

        switch content {
        case .text(let attributed, _):
            addStyleButtons(to: root, width: size.width)
            let view = addTextView(to: root, frame: body, rich: true)
            view.textStorage?.setAttributedString(Self.displayable(attributed))
        case .newText:
            addStyleButtons(to: root, width: size.width)
            _ = addTextView(to: root, frame: body, rich: true)
        case .link(let url):
            let view = addTextView(to: root, frame: body, rich: false)
            view.string = url
            if let target = URL(string: url) {
                let title = NSWorkspace.shared.defaultApplicationName(for: target).map { String(localized: "在 \($0) 中打开") } ?? String(localized: "打开")
                let open = NSButton(title: title, target: self, action: #selector(openLinkClicked))
                open.isBordered = false
                open.font = .systemFont(ofSize: 13, weight: .medium)
                open.contentTintColor = .labelColor
                open.sizeToFit()
                let width = open.frame.width + 16
                open.frame = NSRect(x: size.width - 11 - width, y: body.maxY + 10, width: width, height: 24)
                root.addSubview(open)
                footerLabel.frame.size.width = open.frame.minX - 14 - 11
            }
        case .color(let value):
            hex = value
            swatch.frame = body
            swatch.wantsLayer = true
            swatch.layer?.cornerRadius = 5
            hexLabel.font = .monospacedSystemFont(ofSize: 22.5, weight: .regular)
            hexLabel.alignment = .center
            hexLabel.frame = NSRect(x: 0, y: (body.height - 27) / 2, width: body.width, height: 27)
            swatch.addSubview(hexLabel)
            root.addSubview(swatch)
        case .image(let image):
            originalImage = image
            originalDisplay = ImageEditing.downsampled(image, maxPixel: Self.displayMaxPixel)
            liftedImage = nil
            liftedDisplay = nil
            quarterTurns = 0
            backgroundRemoved = false
            let board = CheckerboardView(frame: body)
            board.wantsLayer = true
            board.layer?.cornerRadius = 5
            board.layer?.masksToBounds = true
            // 比内容区大的图按比例缩小，小图按原尺寸居中。
            imageView.imageScaling = .scaleProportionallyDown
            imageView.frame = board.bounds
            imageView.autoresizingMask = [.width, .height]
            board.addSubview(imageView)
            root.addSubview(board)
            addImageButtons(to: root, width: size.width, includesBackground: false)
            // 识别到主体后才出现“移除背景”按钮。
            liftTask = Task { [weak self] in
                let lifted = await ImageEditing.liftSubject(from: image)
                guard !Task.isCancelled, let lifted else { return }
                let display = await Task.detached(priority: .userInitiated) { ImageEditing.downsampled(lifted, maxPixel: Self.displayMaxPixel) }.value
                guard !Task.isCancelled, let self, self.originalImage === image else { return }
                self.liftedImage = lifted
                self.liftedDisplay = display
                self.addImageButtons(to: root, width: size.width, includesBackground: true)
            }
        }
        refreshFooter()
        return effect
    }

    private func addTextView(to root: NSView, frame: NSRect, rich: Bool) -> NSTextView {
        let scroll = NSScrollView(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = PanelMetrics.contentBackgroundColor
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 5
        scroll.layer?.masksToBounds = true

        let view = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        view.isRichText = rich
        view.importsGraphics = false
        view.usesFontPanel = false
        view.allowsUndo = true
        view.font = Self.defaultFont
        view.textColor = .labelColor
        view.backgroundColor = PanelMetrics.contentBackgroundColor
        view.insertionPointColor = .labelColor
        // 从别处复制来的富文本多半是黑字，深色外观下由系统换成看得清的颜色；存下来的颜色不变。
        view.usesAdaptiveColorMappingForDarkAppearance = true
        // 剪贴板内容要原样保存，不做任何自动替换。
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.textContainerInset = NSSize(width: 8.5, height: 10.5)
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.typingAttributes = [.font: Self.defaultFont, .foregroundColor: NSColor.labelColor]
        view.delegate = self
        scroll.documentView = view
        root.addSubview(scroll)
        textView = view
        return view
    }

    /// B / I / U / S 四个 34 × 24 的按钮，间距 6，整体居中。
    private func addStyleButtons(to root: NSView, width: CGFloat) {
        let items: [(String, String, Selector)] = [
            ("bold", String(localized: "粗体"), #selector(boldClicked)), ("italic", String(localized: "斜体"), #selector(italicClicked)),
            ("underline", String(localized: "下划线"), #selector(underlineClicked)), ("strikethrough", String(localized: "删除线"), #selector(strikeClicked)),
        ]
        var x = ((width - CGFloat(items.count) * 34 - CGFloat(items.count - 1) * 6) / 2).rounded()
        styleButtons = []
        for ((symbol, label, action), style) in zip(items, [TextStyle.bold, .italic, .underline, .strikethrough]) {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) ?? NSImage()
            let button = NSButton(image: image, target: self, action: action)
            button.isBordered = false
            button.setButtonType(.onOff)
            button.contentTintColor = .labelColor
            button.refusesFirstResponder = true
            button.setAccessibilityLabel(label)
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.frame = NSRect(x: x, y: 7, width: 34, height: 24)
            root.addSubview(button)
            styleButtons.append((button, style))
            x += 40
        }
    }

    /// 没有选区时看接下来输入的格式，有选区时看选区是否全带这个格式；生效的按钮垫一层浅底。
    private func refreshStyleButtons() {
        guard let textView, let storage = textView.textStorage, !styleButtons.isEmpty else { return }
        let range = textView.selectedRange()
        let manager = NSFontManager.shared
        func has(_ style: TextStyle, _ attributes: [NSAttributedString.Key: Any]) -> Bool {
            switch style {
            case .bold:
                return manager.traits(of: attributes[.font] as? NSFont ?? Self.defaultFont).contains(.boldFontMask)
            case .italic:
                return Self.isItalic(attributes)
            case .underline: return (attributes[.underlineStyle] as? Int ?? 0) != 0
            case .strikethrough: return (attributes[.strikethroughStyle] as? Int ?? 0) != 0
            }
        }
        for (button, style) in styleButtons {
            var on: Bool
            if range.length == 0 || NSMaxRange(range) > storage.length {
                on = has(style, textView.typingAttributes)
            } else {
                on = true
                storage.enumerateAttributes(in: range) { attributes, _, stop in
                    if !has(style, attributes) { on = false; stop.pointee = true }
                }
            }
            button.state = on ? .on : .off
            button.effectiveAppearance.performAsCurrentDrawingAppearance {
                button.layer?.backgroundColor = on ? NSColor.labelColor.withAlphaComponent(0.16).cgColor : nil
            }
        }
    }

    /// 向左、向右旋转两个 34 × 24 的按钮，整体居中；识别到主体时多一个移除背景。
    private func addImageButtons(to root: NSView, width: CGFloat, includesBackground: Bool) {
        root.subviews.filter { $0.identifier == Self.imageButtonID }.forEach { $0.removeFromSuperview() }
        var items: [(String, String, Selector)] = [
            ("rotate.left", String(localized: "向左旋转"), #selector(rotateLeftClicked)),
            ("rotate.right", String(localized: "向右旋转"), #selector(rotateRightClicked)),
        ]
        if includesBackground { items.append(("person.and.background.dotted", String(localized: "移除背景"), #selector(backgroundClicked))) }
        var x = ((width - CGFloat(items.count) * 34 - CGFloat(items.count - 1) * 6) / 2).rounded()
        for (symbol, label, action) in items {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) ?? NSImage()
            let button = NSButton(image: image, target: self, action: action)
            button.isBordered = false
            button.contentTintColor = .labelColor
            button.refusesFirstResponder = true
            button.identifier = Self.imageButtonID
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.frame = NSRect(x: x, y: 7, width: 34, height: 24)
            root.addSubview(button)
            if action == #selector(backgroundClicked) { backgroundButton = button }
            x += 40
        }
        refreshBackgroundButton()
    }

    private static let imageButtonID = NSUserInterfaceItemIdentifier("imageToolbarButton")

    /// 按当前的旋转和背景状态算出要显示的缩小图，以及原图转过之后的尺寸。
    private var currentDisplay: (image: CGImage, size: NSSize)? {
        guard let original = originalImage, let base = backgroundRemoved ? liftedDisplay : originalDisplay,
              let image = ImageEditing.rotated(base, quarterTurns: quarterTurns) else { return nil }
        let size = quarterTurns % 2 == 1 ? NSSize(width: original.height, height: original.width) : NSSize(width: original.width, height: original.height)
        return (image, size)
    }

    private func refreshBackgroundButton() {
        let label = backgroundRemoved ? String(localized: "还原背景") : String(localized: "移除背景")
        backgroundButton?.toolTip = label
        backgroundButton?.setAccessibilityLabel(label)
        backgroundButton?.contentTintColor = backgroundRemoved ? .controlAccentColor : .labelColor
    }

    private func rotate(by turns: Int) {
        quarterTurns = (quarterTurns + turns + 4) % 4
        imageChanged()
    }

    private func imageChanged() {
        isDirty = quarterTurns != 0 || backgroundRemoved
        refreshBackgroundButton()
        refreshFooter()
    }

    @objc private func rotateLeftClicked() { rotate(by: 1) }
    @objc private func rotateRightClicked() { rotate(by: -1) }
    @objc private func backgroundClicked() {
        guard liftedImage != nil else { return }
        backgroundRemoved.toggle()
        imageChanged()
    }

    private func pillButton(_ title: String, primary: Bool, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.refusesFirstResponder = true
        button.wantsLayer = true
        button.layer?.cornerRadius = 12
        button.contentTintColor = primary ? .white : .labelColor
        button.layer?.backgroundColor = (primary ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.1)).cgColor
        if primary { button.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13, weight: .medium)]) }
        return button
    }

    /// 没有字体的片段补上默认字体、没有颜色的补上跟随外观的文字色，显示才一致。
    private static func displayable(_ attributed: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: attributed)
        result.enumerateAttributes(in: NSRange(location: 0, length: result.length)) { attributes, range, _ in
            if attributes[.font] == nil { result.addAttribute(.font, value: defaultFont, range: range) }
            if attributes[.foregroundColor] == nil { result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range) }
        }
        return result
    }

    private func refreshFooter() {
        switch content {
        case .text, .newText:
            let stats = TextStatistics(textView?.string ?? "")
            footerLabel.attributedStringValue = PreviewText.footer([
                (nil, String(localized: "\(stats.characters) 个字符")), (nil, String(localized: "\(stats.words) 单词")), (nil, String(localized: "\(stats.lines) 行")),
            ])
        case .link:
            footerLabel.attributedStringValue = PreviewText.footer([(nil, (textView?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines))])
        case .color:
            let color = NSColor(hex: hex) ?? .gray
            swatch.layer?.backgroundColor = color.cgColor
            hexLabel.stringValue = hex
            hexLabel.textColor = color.isLight ? .black : .white
            let parts = ColorComponents(hex: hex)
            func list(_ values: [Int]?) -> String { (values ?? []).map(String.init).joined(separator: ", ") }
            footerLabel.attributedStringValue = PreviewText.footer([("RGB", list(parts?.rgb)), ("HSL", list(parts?.hsl)), ("HSB", list(parts?.hsb))])
        case .image:
            guard let (image, size) = currentDisplay else { return }
            // 一个像素按一个点显示，与预览一致；显示的是缩小图，所以按原图尺寸给定大小。
            imageView.image = NSImage(cgImage: image, size: size)
            footerLabel.attributedStringValue = PreviewText.footer([(nil, "\(Int(size.width)) × \(Int(size.height))")])
        }
    }

    // MARK: 颜色

    private func showColorPanel() {
        let colors = NSColorPanel.shared
        colors.showsAlpha = false
        colors.isContinuous = true
        if let color = NSColor(hex: hex) { colors.color = color }
        colors.setTarget(self)
        colors.setAction(#selector(colorPicked(_:)))
        // 本应用不在前台，取色面板默认会跟着隐藏。
        colors.hidesOnDeactivate = false
        colors.orderFront(nil)
    }

    @objc private func colorPicked(_ sender: NSColorPanel) {
        guard isOpen, let picked = sender.color.hexString, picked != hex else { return }
        hex = picked
        isDirty = true
        refreshFooter()
    }

    // MARK: 格式

    private func handleCommand(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return false }
        switch Int(event.keyCode) {
        case 1: finish(save: true) // ⌘S；原版 ⌘Return 不起作用，这里也不做（L26）
        case 13: finish(save: false) // ⌘W
        case 11 where hasStyleButtons: toggleFontTrait(.boldFontMask)
        case 34 where hasStyleButtons: toggleItalic()
        case 32 where hasStyleButtons: toggleLine(.underlineStyle)
        default: return false
        }
        return true
    }

    private var hasStyleButtons: Bool {
        switch content {
        case .text, .newText: true
        case .link, .color, .image: false
        }
    }

    /// 有选区就改选区，没有就改接下来要输入的文字。选区里全都带这个样式时是去掉，否则是加上。
    private static func isItalic(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        NSFontManager.shared.traits(of: attributes[.font] as? NSFont ?? defaultFont).contains(.italicFontMask)
    }

    /// 切换斜体。苹方等中文字体没有斜体样式，换不出来的文字保持原样并在底栏说明，不做倾斜模拟（M5 第 9 步真机：原来点了没有任何反应）。
    private func toggleItalic() {
        guard let textView, let storage = textView.textStorage else { return }
        let manager = NSFontManager.shared
        var unavailable = false
        func converted(_ font: NSFont, on: Bool) -> NSFont {
            guard on else { return manager.convert(font, toNotHaveTrait: .italicFontMask) }
            let italic = manager.convert(font, toHaveTrait: .italicFontMask)
            if manager.traits(of: italic).contains(.italicFontMask) { return italic }
            unavailable = true
            return font
        }
        let range = textView.selectedRange()
        if range.length == 0 {
            let font = textView.typingAttributes[.font] as? NSFont ?? Self.defaultFont
            textView.typingAttributes[.font] = converted(font, on: !Self.isItalic(textView.typingAttributes))
        } else {
            guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
            var allItalic = true
            storage.enumerateAttributes(in: range) { attributes, _, stop in
                if !Self.isItalic(attributes) { allItalic = false; stop.pointee = true }
            }
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: range) { value, part, _ in
                storage.addAttribute(.font, value: converted(value as? NSFont ?? Self.defaultFont, on: !allItalic), range: part)
            }
            storage.endEditing()
            textView.didChangeText()
            isDirty = true
            usedFormatting = true
        }
        refreshStyleButtons()
        if unavailable { showNotice(String(localized: "所选文字的字体没有斜体样式")) }
    }

    /// 底栏临时显示一句说明，几秒后换回字数统计。
    private func showNotice(_ text: String) {
        noticeTask?.cancel()
        footerLabel.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.systemOrange,
        ])
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.refreshFooter()
        }
    }

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        guard let textView, let storage = textView.textStorage else { return }
        let manager = NSFontManager.shared
        func toggled(_ font: NSFont, remove: Bool) -> NSFont {
            remove ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
        }
        let range = textView.selectedRange()
        if range.length == 0 {
            let font = textView.typingAttributes[.font] as? NSFont ?? Self.defaultFont
            textView.typingAttributes[.font] = toggled(font, remove: manager.traits(of: font).contains(trait))
        } else {
            guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
            var allHave = true
            storage.enumerateAttribute(.font, in: range) { value, _, _ in
                if !manager.traits(of: value as? NSFont ?? Self.defaultFont).contains(trait) { allHave = false }
            }
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: range) { value, part, _ in
                storage.addAttribute(.font, value: toggled(value as? NSFont ?? Self.defaultFont, remove: allHave), range: part)
            }
            storage.endEditing()
            textView.didChangeText()
        }
        isDirty = true
        usedFormatting = true
        refreshStyleButtons()
    }

    private func toggleLine(_ key: NSAttributedString.Key) {
        guard let textView, let storage = textView.textStorage else { return }
        func isOn(_ value: Any?) -> Bool { (value as? Int ?? 0) != 0 }
        let range = textView.selectedRange()
        if range.length == 0 {
            if isOn(textView.typingAttributes[key]) { textView.typingAttributes[key] = nil } else { textView.typingAttributes[key] = NSUnderlineStyle.single.rawValue }
        } else {
            guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
            var allOn = true
            storage.enumerateAttribute(key, in: range) { value, _, _ in if !isOn(value) { allOn = false } }
            if allOn { storage.removeAttribute(key, range: range) } else { storage.addAttribute(key, value: NSUnderlineStyle.single.rawValue, range: range) }
            textView.didChangeText()
        }
        isDirty = true
        usedFormatting = true
        refreshStyleButtons()
    }

    @objc private func boldClicked() { toggleFontTrait(.boldFontMask) }
    @objc private func italicClicked() { toggleItalic() }
    @objc private func underlineClicked() { toggleLine(.underlineStyle) }
    @objc private func strikeClicked() { toggleLine(.strikethroughStyle) }
    @objc private func cancelClicked() { finish(save: false) }
    @objc private func saveClicked() { finish(save: true) }

    @objc private func openLinkClicked() {
        guard let url = URL(string: (textView?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) else { NSSound.beep(); return }
        NSWorkspace.shared.open(url)
    }

    // MARK: 结束

    private func finish(save: Bool) {
        guard window != nil, pendingSave == nil else { return }
        // 图片的结果要转整张原图再编码成 PNG，大图要零点几秒，放到后台做（L28）。
        // 编码和写库都成功后才关窗口：失败时编辑现场还在，可以重试或取消（审查 15）。
        if save, isDirty, case .image = content, let base = backgroundRemoved ? liftedImage : originalImage {
            let turns = quarterTurns
            setSaving(true)
            pendingSave = Task { [weak self] in
                let data = await Task.detached(priority: .userInitiated) {
                    ImageEditing.rotated(base, quarterTurns: turns).flatMap(ImageEditing.png)
                }.value
                guard let self else { return }
                self.pendingSave = nil
                guard let data else {
                    self.setSaving(false)
                    self.showSaveFailure(String(localized: "没能生成图片"))
                    return
                }
                self.commit(.image(data))
            }
            return
        }
        guard save, isDirty, let result = currentResult() else {
            let completion = completion
            close()
            try? completion?(nil)
            return
        }
        commit(result)
    }

    /// 交给调用方写库；成功才关窗口。
    private func commit(_ result: EditorResult) {
        do {
            try completion?(result)
            close()
        } catch {
            setSaving(false)
            showSaveFailure(error.localizedDescription)
        }
    }

    private func showSaveFailure(_ reason: String) {
        NSSound.beep()
        showNotice(String(localized: "保存失败：\(reason)"))
    }

    /// 保存进行中时按钮不可用。
    private func setSaving(_ saving: Bool) {
        func walk(_ view: NSView) {
            if let control = view as? NSButton { control.isEnabled = !saving }
            view.subviews.forEach(walk)
        }
        if let contentView = window?.contentView { walk(contentView) }
        textView?.isEditable = !saving
    }

    /// 关窗口并放掉全部内容，包括长期持有的 `content`（大图或整段富文本，审查 12）。
    private func close() {
        guard let window else { return }
        if case .color = content {
            NSColorPanel.shared.setTarget(nil)
            NSColorPanel.shared.setAction(nil)
            NSColorPanel.shared.orderOut(nil)
        }
        liftTask?.cancel()
        liftTask = nil
        backgroundButton = nil
        originalImage = nil
        liftedImage = nil
        originalDisplay = nil
        liftedDisplay = nil
        imageView.image = nil
        content = .newText
        completion = nil
        self.window = nil
        textView?.delegate = nil
        textView = nil
        window.orderOut(nil)
        window.close()
    }

    /// 内容为空时返回 nil：不保存空条目。
    private func currentResult() -> EditorResult? {
        switch content {
        case .text(_, let isRich):
            return textResult(rich: isRich || usedFormatting)
        case .newText:
            return textResult(rich: usedFormatting)
        case .link:
            let url = (textView?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return url.isEmpty ? nil : .link(url)
        case .color:
            return .color(hex)
        case .image:
            // 图片在 finish 里单独处理。
            return nil
        }
    }

    private func textResult(rich: Bool) -> EditorResult? {
        guard let storage = textView?.textStorage, storage.length > 0 else { return nil }
        guard rich else { return .text(plain: storage.string, rtf: nil) }
        // 默认的文字颜色跟随外观，写进 RTF 会变成固定的白色或黑色，导出前去掉。
        let export = NSMutableAttributedString(attributedString: storage)
        export.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: export.length)) { value, range, _ in
            if (value as? NSColor) == NSColor.labelColor { export.removeAttribute(.foregroundColor, range: range) }
        }
        let rtf = export.rtf(from: NSRange(location: 0, length: export.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        return .text(plain: storage.string, rtf: rtf)
    }
}

extension EditorController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        isDirty = true
        refreshFooter()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        refreshStyleButtons()
    }

    // 输入法组字期间 Esc 不会走到这里，取消的是组字。
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        finish(save: false)
        return true
    }
}

#if DEBUG
extension EditorController {
    var debugWindowSize: NSSize? { window?.frame.size }
    var debugTextView: NSTextView? { textView }
    /// 结束编辑；图片要等后台的旋转和编码写完再返回。
    func debugFinish(save: Bool) async {
        finish(save: save)
        await pendingSave?.value
    }
    func debugToggleBold() { toggleFontTrait(.boldFontMask) }
    func debugToggleItalic() { toggleItalic() }
    var debugFooterText: String { footerLabel.stringValue }
    /// 依次是 B、I、U、S 按钮当前是否显示为已生效。
    var debugStyleStates: [Bool] { styleButtons.map { $0.button.state == .on } }
    func debugRotateLeft() { rotate(by: 1) }
    var debugCanRemoveBackground: Bool { liftedImage != nil }
    func debugToggleBackground() { backgroundClicked() }
    func debugPickColor(_ value: String) {
        hex = value
        isDirty = true
        refreshFooter()
    }
}
#endif
