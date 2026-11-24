import AppKit
import ClipboardKit
import PasteCore
import Quartz
import UniformTypeIdentifiers
import VisionKit
import WebKit

/// 预览浮层内容区按类型显示的东西。
enum PreviewContent {
    /// `rich` 是条目带的富文本，有就按富文本显示（原版如此，L05）。
    case text(String, rich: NSAttributedString?)
    case color(NSColor, hex: String)
    /// `pixelSize` 是原图像素数，`contentSize` 是按它算好的内容区尺寸。
    /// 图片为 nil 时先只显示转圈，原图在后台解码好再用 `setImage` 放进来（L09）。
    case image(NSImage?, pixelSize: NSSize, contentSize: NSSize)
    /// 网页预览。`notice` 不为空时不加载网页，只显示这句说明（预览被关掉，或者是内网地址）。
    /// `openTitle` 是底栏右侧按钮的标题，`size` 是浮层尺寸。
    case link(URL, notice: String?, openTitle: String, size: NSSize)
    /// 单个文件用系统的快速查看；多个文件只显示叠放的文稿图标。
    /// `recordedBytes`：复制时记下的大小，文件都不在了时显示它。
    case files([URL], recordedBytes: Int64?, size: NSSize)
    /// 内容读不出来。
    case unavailable

    /// 预览里实际显示的文本，量尺寸和显示用同一份。
    static func displayText(_ text: String, rich: NSAttributedString?) -> NSAttributedString {
        rich.map { RichTextDisplay.prepare($0, font: .systemFont(ofSize: 13)) }
            ?? NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
    }

    var size: NSSize {
        switch self {
        case .color: PanelMetrics.previewColorSize
        case .image(_, _, let contentSize): PanelMetrics.previewSize(forContent: contentSize)
        case .link(_, _, _, let size), .files(_, _, let size): size
        case .text(let text, let rich):
            // 按排版量尺寸，长文本的浮层会变宽变高（原版 6.6.2 的做法）；屏幕取 `NSScreen.main`，和原版一致。
            PanelMetrics.previewSize(forContent: PanelMetrics.previewTextContentSize(
                Self.displayText(text, rich: rich), screenSize: NSScreen.main?.frame.size ?? NSSize(width: 1800, height: 1169)))
        case .unavailable: PanelMetrics.previewTextSize
        }
    }
}

/// 空格预览：锚定在所选卡片上方、带向下箭头的系统弹出框。
@MainActor
final class PreviewPopover: NSObject {
    /// 浮层成为 key 窗口时（点了里面的文字）按键先交给面板处理。返回 true 表示已处理。
    var onKey: ((NSEvent) -> Bool)?
    var onCloseButton: (() -> Void)?
    /// 顶栏固定按钮的菜单。
    var pinMenu: (() -> NSMenu?)?
    /// 浮层失去键盘焦点。
    var onResignKey: (() -> Void)?
    /// 底栏右侧的按钮（在浏览器中打开、在 Finder 中显示）。
    var onFooterAction: (() -> Void)?
    /// 顶栏的分享按钮，参数是按钮本身，供分享菜单定位。
    var onShare: ((NSView) -> Void)?
    var onEdit: (() -> Void)?

    private let popover = NSPopover()
    private let controller = PreviewViewController()
    private var resignObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private weak var anchorWindow: NSWindow?
    private(set) var clipID: ClipSummary.ID?

    var isShown: Bool { popover.isShown }
    var window: NSWindow? { controller.viewIfLoaded?.window }
    /// 当前显示的是图片，但原图还没解码好。
    var awaitsImage: Bool { popover.isShown && controller.awaitsImage }
    var showsImage: Bool { popover.isShown && controller.showsImage }
    /// 文本预览当前显示的内容（含格式）。
    var shownText: NSAttributedString? { popover.isShown ? controller.shownText : nil }

    /// 后台解码好的原图。期间已经切到别的条目或关掉浮层就丢弃。
    func setImage(_ image: NSImage?, for id: ClipSummary.ID) {
        guard popover.isShown, clipID == id else { return }
        controller.setImage(image)
    }

    override init() {
        super.init()
        popover.contentViewController = controller
        // 关闭时机全部由面板决定：切换条目时浮层要留着。
        popover.behavior = .applicationDefined
        popover.animates = false
        controller.onClose = { [weak self] in self?.onCloseButton?() }
        controller.pinMenu = { [weak self] in self?.pinMenu?() }
        controller.onFooterAction = { [weak self] in self?.onFooterAction?() }
        controller.onShare = { [weak self] in self?.onShare?($0) }
        controller.onEdit = { [weak self] in self?.onEdit?() }
    }

    /// 显示或切换到另一条。同一条再次调用只更新位置，不重置滚动位置和选区。
    func show(clip: ClipSummary, content: @autoclosure () -> PreviewContent, relativeTo rect: NSRect, of view: NSView) {
        if clip.id != clipID || !popover.isShown {
            let content = content()
            controller.configure(title: ClipCardItem.typeTitle(for: clip), content: content)
            popover.contentSize = content.size
            clipID = clip.id
        }
        if popover.isShown {
            popover.positioningRect = rect
        } else {
            anchorWindow = view.window
            popover.show(relativeTo: rect, of: view, preferredEdge: view.isFlipped ? .minY : .maxY)
            if let window { WindowSharing.apply(to: window) }
            observeResign()
            installKeyMonitor()
        }
    }

    func move(to rect: NSRect) {
        guard popover.isShown else { return }
        popover.positioningRect = rect
    }

    func close() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        clipID = nil
        // 网页视图和快速查看各带一个辅助进程，浮层关掉就放掉。
        controller.releaseHeavyViews()
        guard popover.isShown else { return }
        popover.close()
    }

    /// 预览打开期间，面板和浮层两个窗口的按键都先在这里交给面板处理。
    /// 不能靠正常的派发和响应链：浮层有焦点时滚动视图会吃掉方向键、弹出框会吃掉 Esc；
    /// 弹出框显示后，面板的第一响应者也不再是卡片区（实测会变成窗口本身或浮层里的文本视图）。
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        // 点回面板时收回网页的焦点，方向键等重新归面板。
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window !== self.window, self.controller.webViewHasFocus else { return }
                self.window?.makeFirstResponder(nil)
            }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let source = event.window, source === self.window || source === self.anchorWindow else { return false }
                // 点进网页之后按键交给网页，才能在页面里打字（L15）；Esc 仍然关预览。
                // 不看按键来自哪个窗口：浮层不在前台的应用里，点进网页后按键事件仍记在面板名下。
                if self.controller.webViewHasFocus, event.keyCode != 53 { return false }
                // ⌘C、⌘A 先看预览里有没有文字选区要用；没有的话 ⌘C 是复制整个条目。
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags == .command, let character = event.charactersIgnoringModifiers?.lowercased(), ["c", "a"].contains(character) {
                    if self.controller.handleLiveTextCommand(character) { return true }
                    // 浮层有焦点时（点过文本预览里的文字）走正常派发，交给里面的文本视图。
                    if source === self.window { return false }
                }
                return self.onKey?(event) == true
            }
            return handled ? nil : event
        }
    }

    private func observeResign() {
        guard resignObserver == nil, let window else { return }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onResignKey?() }
        }
    }
}

/// 网页预览的拦截规则：页面里的子资源不经过导航检查，用它挡住本机和内网地址（L11）。
@MainActor
enum PreviewWebRules {
    /// 拦截规则编译一次后复用。
    private static var privateAddressRules: WKContentRuleList?

    /// 写成 IP 字面地址或本机名称的本机、内网地址。只能按地址的写法拦：域名解析到内网的子资源 WebKit 不给机会检查。
    /// WebKit 的规则正则不支持“或”，每个网段单独一条。
    static let privateAddressPatterns = [
        "^[^:]+://localhost[:/]", "^[^:]+://[^/]*\\.localhost[:/]", "^[^:]+://[^/]*\\.local[:/]", "^[^:]+://[^/.]+[:/]",
        "^[^:]+://0\\.", "^[^:]+://10\\.", "^[^:]+://127\\.", "^[^:]+://169\\.254\\.", "^[^:]+://192\\.168\\.",
        "^[^:]+://172\\.1[6-9]\\.", "^[^:]+://172\\.2[0-9]\\.", "^[^:]+://172\\.3[01]\\.",
        "^[^:]+://100\\.6[4-9]\\.", "^[^:]+://100\\.[7-9][0-9]\\.", "^[^:]+://100\\.1[01][0-9]\\.", "^[^:]+://100\\.12[0-7]\\.",
        // IPv6 字面地址一律不放行，公开网页几乎不会这样写。
        "^[^:]+://\\[",
    ]

    /// 拿到编译好的规则再继续；编译失败时为 nil，调用方不加载网页。
    static func withPrivateAddressRules(_ body: @escaping @MainActor (WKContentRuleList?) -> Void) {
        if let rules = privateAddressRules { return body(rules) }
        let rules = privateAddressPatterns.map { ["trigger": ["url-filter": $0], "action": ["type": "block"]] }
        guard let data = try? JSONSerialization.data(withJSONObject: rules), let json = String(data: data, encoding: .utf8),
              let store = WKContentRuleListStore.default() else { return body(nil) }
        store.compileContentRuleList(forIdentifier: "XPastePrivateAddresses", encodedContentRuleList: json) { list, error in
            if let error { Log.link.error("编译预览拦截规则失败: \(String(describing: error))") }
            MainActor.assumeIsolated {
                privateAddressRules = list
                body(list)
            }
        }
    }
}

/// 预览和编辑窗口底栏共用的排版。
enum PreviewText {
    /// 底栏的一行：各段用圆点隔开，段前可带一个颜色更淡的标签。
    static func footer(_ segments: [(tag: String?, value: String)]) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 13)
        let dim: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let normal: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let line = NSMutableAttributedString()
        // 间距按截图对出来：圆点前 10、后 8，标签和数值之间 5。用字距加在每段最后一个字符后面。
        func append(_ text: String, _ attributes: [NSAttributedString.Key: Any], gapAfter: CGFloat) {
            line.append(NSAttributedString(string: text, attributes: attributes))
            if gapAfter > 0, line.length > 0 { line.addAttribute(.kern, value: gapAfter, range: NSRange(location: line.length - 1, length: 1)) }
        }
        for (index, segment) in segments.enumerated() {
            if let tag = segment.tag { append(tag, dim, gapAfter: 5) }
            let isLast = index == segments.count - 1
            append(segment.value, normal, gapAfter: isLast ? 0 : 10)
            if !isLast { append("·", dim, gapAfter: 8) }
        }
        return line
    }
}

/// 坐标原点在左上的根视图，方便按实测数值摆放。
private final class PreviewRootView: NSView {
    override var isFlipped: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // 后台应用没有“编辑”菜单，选中文字（包括图片里的实况文本）后的 ⌘C、⌘A 要自己转发。
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, window?.isKeyWindow == true {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
            case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// 浮层里的按钮。本应用不在前台，浮层也不是 key 窗口，普通按钮会把第一次点击只当成激活窗口。
private final class PreviewButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 文档比可见区域小时把它放在正中的裁剪视图。
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if document.frame.width < rect.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if document.frame.height < rect.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

/// 图片四周和透明区域后面的半透明棋盘格。
final class CheckerboardView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let cell: CGFloat = 8
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        bounds.fill(using: .sourceOver)
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        for row in 0..<Int((bounds.height / cell).rounded(.up)) {
            for column in stride(from: row % 2, to: Int((bounds.width / cell).rounded(.up)), by: 2) {
                NSRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell).fill(using: .sourceOver)
            }
        }
    }
}

@MainActor
private final class PreviewViewController: NSViewController {
    var onClose: (() -> Void)?
    var pinMenu: (() -> NSMenu?)?
    var onFooterAction: (() -> Void)?
    var onShare: ((NSView) -> Void)?
    var onEdit: (() -> Void)?

    private let closeButton = PreviewViewController.iconButton("xmark.circle.fill", pointSize: 13, label: String(localized: "关闭"))
    private let titleLabel = NSTextField(labelWithString: "")
    private let pinButton = PreviewButton(title: "", target: nil, action: nil)
    private let shareButton = PreviewViewController.iconButton("square.and.arrow.up", pointSize: 13, label: String(localized: "分享"))
    private let editButton = PreviewButton(title: String(localized: "编辑"), target: nil, action: nil)
    private let footerLabel = NSTextField(labelWithString: "")

    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let colorView = NSView()
    private let checkerboard = CheckerboardView()
    private let imageScroll = NSScrollView()
    private let imageView = NSImageView()
    private let liveText = ImageAnalysisOverlayView()
    private var imagePixelSize = NSSize.zero
    private var analysisTask: Task<Void, Never>?
    private(set) var awaitsImage = false
    var showsImage: Bool { !imageScroll.isHidden && imageView.image != nil }
    var shownText: NSAttributedString? { scrollView.isHidden ? nil : textView.attributedString() }
    private let colorLabel = NSTextField(labelWithString: "")
    private static let unavailableTitleText = String(localized: "无法预览")
    private static let unavailableDetailText = String(localized: "这项内容已保存，仍然可以粘贴。")
    private let unavailableTitle = NSTextField(labelWithString: unavailableTitleText)
    private let unavailableDetail = NSTextField(labelWithString: unavailableDetailText)
    private var colorFill: NSColor?

    // 链接和文件预览。网页视图和快速查看视图用到时才创建。
    private var webView: WKWebView?
    /// 等拦截规则编好后要加载的页面；换了内容或关掉浮层就清掉。
    private var pendingPage: URL?
    private var quickLook: QLPreviewView?
    private var fileCheckTask: Task<Void, Never>?
    private let spinner = NSProgressIndicator()
    private let fileIconBack = NSImageView()
    private let fileIcon = NSImageView()
    private let footerButton = PreviewButton(title: "", target: nil, action: nil)
    private var footerHeight = PanelMetrics.previewFooterHeight

    override func loadView() {
        let root = PreviewRootView()
        view = root

        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        // 虚线圆加一个向下的小箭头，表示点开是菜单。
        let pinTitle = NSMutableAttributedString()
        for (symbol, size) in [("circle.dashed", 13.0), ("chevron.down", 7.0)] {
            let attachment = NSTextAttachment()
            attachment.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))
            if pinTitle.length > 0 { pinTitle.append(NSAttributedString(string: " ")) }
            pinTitle.append(NSAttributedString(attachment: attachment))
        }
        pinTitle.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .baselineOffset: 1], range: NSRange(location: 0, length: pinTitle.length))
        pinButton.attributedTitle = pinTitle
        pinButton.isBordered = false
        // 标题是两个图标附件，读出来是空白，辅助功能的标题也换成文字。
        pinButton.setAccessibilityTitle(String(localized: "固定"))
        pinButton.setAccessibilityLabel(String(localized: "固定"))
        pinButton.target = self
        pinButton.action = #selector(pinClicked)

        shareButton.contentTintColor = .secondaryLabelColor
        shareButton.target = self
        shareButton.action = #selector(shareClicked)

        footerButton.isBordered = false
        footerButton.font = .systemFont(ofSize: 13, weight: .medium)
        footerButton.contentTintColor = .labelColor
        footerButton.target = self
        footerButton.action = #selector(footerClicked)

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        for icon in [fileIconBack, fileIcon] { icon.imageScaling = .scaleProportionallyUpOrDown }

        // 很淡的胶囊底，系统的玻璃按钮样式在这里太亮。
        editButton.isBordered = false
        editButton.font = .systemFont(ofSize: 13, weight: .medium)
        editButton.contentTintColor = .labelColor
        editButton.wantsLayer = true
        editButton.layer?.cornerRadius = 12
        editButton.layer?.borderWidth = 0.5
        editButton.target = self
        editButton.action = #selector(editClicked)

        // 键盘留给面板，顶栏按钮不参与焦点。
        for button in [closeButton, pinButton, shareButton, editButton, footerButton] { button.refusesFirstResponder = true }

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.backgroundColor = PanelMetrics.contentBackgroundColor
        // 文字距内容区左边 13.5、上边 10.5（行片段自带 5 的左右留白）。
        textView.textContainerInset = NSSize(width: 8.5, height: 10.5)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = PanelMetrics.contentBackgroundColor
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = PanelMetrics.previewContentCornerRadius
        scrollView.layer?.masksToBounds = true

        colorView.wantsLayer = true
        colorView.layer?.cornerRadius = PanelMetrics.previewContentCornerRadius
        colorLabel.font = .monospacedSystemFont(ofSize: 22.5, weight: .regular)
        colorLabel.alignment = .center
        colorView.addSubview(colorLabel)

        checkerboard.wantsLayer = true
        checkerboard.layer?.cornerRadius = PanelMetrics.previewContentCornerRadius
        checkerboard.layer?.masksToBounds = true

        imageView.imageScaling = .scaleAxesIndependently
        // 实况文本：识别到文字后图片右下角出现系统的按钮，可以选中、复制图中的文字。
        liveText.preferredInteractionTypes = .automatic
        liveText.trackingImageView = imageView
        liveText.autoresizingMask = [.width, .height]
        imageView.addSubview(liveText)

        imageScroll.contentView = CenteringClipView()
        imageScroll.documentView = imageView
        imageScroll.drawsBackground = false
        imageScroll.hasVerticalScroller = true
        imageScroll.hasHorizontalScroller = true
        imageScroll.allowsMagnification = true
        imageScroll.minMagnification = 1
        imageScroll.maxMagnification = 8
        imageScroll.wantsLayer = true
        imageScroll.layer?.cornerRadius = PanelMetrics.previewContentCornerRadius
        imageScroll.layer?.masksToBounds = true

        unavailableTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        unavailableTitle.textColor = .secondaryLabelColor
        unavailableTitle.alignment = .center
        unavailableDetail.font = .systemFont(ofSize: 13)
        unavailableDetail.textColor = .tertiaryLabelColor
        unavailableDetail.alignment = .center

        footerLabel.lineBreakMode = .byTruncatingTail

        for sub in [closeButton, titleLabel, pinButton, shareButton, editButton, scrollView, colorView, checkerboard, imageScroll, fileIconBack, fileIcon,
                    spinner, unavailableTitle, unavailableDetail, footerLabel, footerButton] {
            root.addSubview(sub)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let m = PanelMetrics.self
        let bounds = view.bounds
        let buttonY: CGFloat = 7

        closeButton.frame = NSRect(x: 9, y: 13, width: 17, height: 11)
        var right = bounds.width - 7
        for (button, width) in [(editButton, 48.0), (shareButton, 34.0), (pinButton, 45.0)] where !button.isHidden {
            button.frame = NSRect(x: right - width, y: buttonY, width: width, height: 24)
            right -= width + 6
        }
        titleLabel.frame = NSRect(x: 31, y: 11, width: max(0, right - 31), height: 18)

        // 底栏：右侧有按钮时高 45，左侧文字折成两行时高 55，否则 38（Docs/归档/调研/08 第 9.13 节）。
        var labelWidth = bounds.width - 22
        if !footerButton.isHidden {
            footerButton.sizeToFit()
            let width = footerButton.frame.width + 16
            footerButton.frame = NSRect(x: bounds.width - 11 - width, y: 0, width: width, height: 24)
            labelWidth = footerButton.frame.minX - 14 - 11
        }
        let textHeight = footerLabel.attributedStringValue.boundingRect(with: NSSize(width: labelWidth - 4, height: 200), options: [.usesLineFragmentOrigin]).height
        let twoLines = footerLabel.maximumNumberOfLines == 2 && textHeight > 22
        footerHeight = twoLines ? m.previewTwoLineFooterHeight : (footerButton.isHidden ? m.previewFooterHeight : m.previewButtonFooterHeight)
        let footerTop = bounds.height - footerHeight
        footerButton.frame.origin.y = footerTop + ((footerHeight - 24) / 2).rounded()

        let content = NSRect(x: m.previewContentInset, y: m.previewHeaderHeight, width: bounds.width - m.previewContentInset * 2,
                             height: bounds.height - m.previewHeaderHeight - footerHeight)
        webView?.frame = content
        quickLook?.frame = content
        spinner.sizeToFit()
        spinner.frame.origin = NSPoint(x: content.midX - spinner.frame.width / 2, y: content.midY - spinner.frame.height / 2)
        // 文件读不了时图标和说明一起显示：图标小一点、往上移，文字在下面（L114 真机：原来文字压在图标上）。
        let withNotice = !unavailableTitle.isHidden && !fileIcon.isHidden
        let iconSide: CGFloat = withNotice ? 128 : fileIconBack.isHidden ? 256 : 160
        let iconTop = withNotice ? content.midY - iconSide - 8 : content.midY - iconSide / 2
        fileIcon.frame = NSRect(x: content.midX - iconSide / 2, y: iconTop, width: iconSide, height: iconSide)
        fileIconBack.frame = fileIcon.frame.offsetBy(dx: -8, dy: 8)
        scrollView.frame = content
        colorView.frame = content
        checkerboard.frame = content
        if imageScroll.frame != content {
            imageScroll.frame = content
            imageScroll.magnification = 1
            let scale = PanelMetrics.previewImageScale(pixelSize: imagePixelSize, fitting: content.size)
            imageView.frame = NSRect(x: 0, y: 0, width: (imagePixelSize.width * scale).rounded(), height: (imagePixelSize.height * scale).rounded())
            liveText.frame = imageView.bounds
        }
        colorLabel.frame = NSRect(x: 0, y: (content.height - 27) / 2, width: content.width, height: 27)
        let textTop = withNotice ? content.midY + 16 : content.midY - 24
        unavailableTitle.frame = NSRect(x: content.minX, y: textTop, width: content.width, height: 20)
        unavailableDetail.frame = NSRect(x: content.minX, y: textTop + 26, width: content.width, height: 18)
        footerLabel.frame = NSRect(x: 11, y: footerTop + (footerButton.isHidden || twoLines ? 10 : 14), width: labelWidth, height: twoLines ? 34 : 18)

        // 图层颜色不会随外观自动更新，每次布局时重新取。
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            colorView.layer?.backgroundColor = colorFill?.cgColor
            editButton.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            editButton.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        }
    }

    func configure(title: String, content: PreviewContent) {
        loadViewIfNeeded()
        titleLabel.stringValue = title
        scrollView.isHidden = true
        colorView.isHidden = true
        checkerboard.isHidden = true
        imageScroll.isHidden = true
        analysisTask?.cancel()
        analysisTask = nil
        liveText.analysis = nil
        imageView.image = nil
        awaitsImage = false
        unavailableTitle.isHidden = true
        unavailableDetail.isHidden = true
        unavailableTitle.stringValue = Self.unavailableTitleText
        unavailableDetail.stringValue = Self.unavailableDetailText
        colorFill = nil
        releaseHeavyViews()
        fileIcon.isHidden = true
        fileIconBack.isHidden = true
        footerButton.isHidden = true
        editButton.isHidden = false
        shareButton.isEnabled = true
        footerLabel.maximumNumberOfLines = 1
        footerLabel.lineBreakMode = .byTruncatingTail
        unavailableTitle.stringValue = String(localized: "无法预览")
        unavailableDetail.stringValue = String(localized: "这项内容已保存，仍然可以粘贴。")

        switch content {
        case .text(let text, let rich):
            scrollView.isHidden = false
            textView.isRichText = rich != nil
            textView.textStorage?.setAttributedString(PreviewContent.displayText(text, rich: rich))
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollToBeginningOfDocument(nil)
            let stats = TextStatistics(text)
            footerLabel.attributedStringValue = PreviewText.footer([
                (nil, String(localized: "\(stats.characters) 个字符")),
                (nil, String(localized: "\(stats.words) 单词")),
                (nil, String(localized: "\(stats.lines) 行")),
            ])
        case .color(let color, let hex):
            colorView.isHidden = false
            colorFill = color
            colorLabel.stringValue = hex
            colorLabel.textColor = color.isLight ? .black : .white
            let parts = ColorComponents(hex: hex)
            func list(_ values: [Int]?) -> String { (values ?? []).map(String.init).joined(separator: ", ") }
            footerLabel.attributedStringValue = PreviewText.footer([("RGB", list(parts?.rgb)), ("HSL", list(parts?.hsl)), ("HSB", list(parts?.hsb))])
        case .image(let image, let pixelSize, _):
            checkerboard.isHidden = false
            imageScroll.isHidden = false
            imagePixelSize = pixelSize
            // 让下一次布局按新图片重新摆放。
            imageScroll.frame = .zero
            footerLabel.attributedStringValue = PreviewText.footer([(nil, "\(Int(pixelSize.width)) × \(Int(pixelSize.height))")])
            awaitsImage = image == nil
            if let image { setImage(image) } else { spinner.startAnimation(nil) }
        case .link(let url, let notice, let openTitle, _):
            footerButton.isHidden = false
            footerButton.title = openTitle
            footerLabel.attributedStringValue = PreviewText.footer([(nil, url.absoluteString)])
            if let notice {
                unavailableTitle.isHidden = false
                unavailableDetail.isHidden = false
                unavailableTitle.stringValue = notice
            } else {
                loadPage(url)
            }
        case .files(let urls, let recordedBytes, _):
            editButton.isHidden = true
            footerButton.isHidden = false
            footerButton.title = String(localized: "在 Finder 中显示")
            let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            shareButton.isEnabled = !existing.isEmpty
            // 目录不算大小；文件都不在了就显示复制时记下的大小（原版如此，L13），旧条目没记就只显示路径。
            let bytes = existing.compactMap { try? $0.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) }
                .filter { $0.isRegularFile == true }.compactMap(\.fileSize)
            let total = bytes.isEmpty ? (existing.isEmpty ? recordedBytes : nil) : Int64(bytes.reduce(0, +))
            let size = total.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            let name = urls.count > 1 ? String(localized: "多个文件") : urls[0].path
            footerLabel.maximumNumberOfLines = 2
            footerLabel.lineBreakMode = .byWordWrapping
            footerLabel.attributedStringValue = PreviewText.footer([(nil, name)] + (size.map { [(nil, $0)] } ?? []))
            if urls.count > 1 {
                let stack = NSWorkspace.shared.icon(for: .data)
                fileIcon.image = stack
                fileIconBack.image = stack
                fileIcon.isHidden = false
                fileIconBack.isHidden = false
            } else if existing.isEmpty {
                // 文件已经不在了：和原版一样只显示这种类型的图标。
                fileIcon.image = NSWorkspace.shared.icon(for: UTType(filenameExtension: urls[0].pathExtension) ?? .data)
                fileIcon.isHidden = false
            } else {
                showFileWhenReadable(urls[0])
            }
        case .unavailable:
            unavailableTitle.isHidden = false
            unavailableDetail.isHidden = false
            footerLabel.stringValue = ""
        }
        view.needsLayout = true
    }

    /// 图片预览里实况文本的 ⌘A（全选图中文字）和 ⌘C（复制选中的文字）。返回 false 表示这次按键与实况文本无关。
    /// 直接操作选区而不走响应链：按键到来时键盘焦点不一定在浮层里。
    /// 浮层窗口的第一响应者在网页视图里，即用户点进了页面。
    var webViewHasFocus: Bool {
        guard let webView, let responder = view.window?.firstResponder as? NSView else { return false }
        return responder === webView || responder.isDescendant(of: webView)
    }

    func handleLiveTextCommand(_ character: String) -> Bool {
        guard !imageScroll.isHidden, liveText.analysis != nil else { return false }
        switch character {
        case "a":
            // 只有用户已经在选字（点了实况文本按钮或拖选过）时才接管全选。
            guard liveText.selectableItemsHighlighted || liveText.hasActiveTextSelection, !liveText.text.isEmpty else { return false }
            liveText.selectedRanges = [liveText.text.startIndex..<liveText.text.endIndex]
            return true
        case "c":
            guard liveText.hasActiveTextSelection, !liveText.selectedText.isEmpty else { return false }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(liveText.selectedText, forType: .string)
            return true
        default:
            return false
        }
    }

    /// 放进图片预览的原图。nil 表示读不出来。
    func setImage(_ image: NSImage?) {
        awaitsImage = false
        spinner.stopAnimation(nil)
        guard let image else {
            checkerboard.isHidden = true
            imageScroll.isHidden = true
            unavailableTitle.isHidden = false
            unavailableDetail.isHidden = false
            return
        }
        imageView.image = image
        analyze(image)
    }

    /// 放掉网页视图、快速查看视图和解码好的原图。切到别的条目或浮层关闭时调用。
    /// 原图解码后按像素占内存（4800 万像素约 190 MB），浮层关了不能还留着。
    func releaseHeavyViews() {
        spinner.stopAnimation(nil)
        fileCheckTask?.cancel()
        fileCheckTask = nil
        analysisTask?.cancel()
        analysisTask = nil
        liveText.analysis = nil
        imageView.image = nil
        awaitsImage = false
        pendingPage = nil
        if let webView {
            webView.navigationDelegate = nil
            webView.stopLoading()
            webView.removeFromSuperview()
        }
        webView = nil
        if let quickLook {
            quickLook.close()
            quickLook.removeFromSuperview()
        }
        quickLook = nil
    }

    private func loadPage(_ url: URL) {
        pendingPage = url
        spinner.startAnimation(nil)
        Task { [weak self] in
            // 网址写法像公开网址、域名却解析到本机或内网时，和写成内网地址一样不加载（L100）。
            let isPublic = await LinkMetadataFetcher.isPublicURL(url)
            guard let self, self.pendingPage == url else { return }
            if isPublic { self.loadCheckedPage(url) } else { self.showPrivateAddressNotice() }
        }
    }

    private func showPrivateAddressNotice() {
        pendingPage = nil
        spinner.stopAnimation(nil)
        unavailableTitle.stringValue = String(localized: "不预览本机和内网地址")
        unavailableTitle.isHidden = false
        unavailableDetail.isHidden = false
    }

    private func loadCheckedPage(_ url: URL) {
        // 页面里的图片、脚本等子资源不经过导航检查，先拿到拦截本机和内网地址的规则再加载（L11）。
        PreviewWebRules.withPrivateAddressRules { [weak self] rules in
            guard let self, self.pendingPage == url else { return }
            self.pendingPage = nil
            // 拦截规则没编译出来时不加载网页（审查 13）：子资源会不受检查地访问本机和内网地址，只显示地址。
            guard let rules else {
                self.spinner.stopAnimation(nil)
                self.unavailableTitle.stringValue = String(localized: "无法安全地预览这个网页")
                self.unavailableTitle.isHidden = false
                self.unavailableDetail.isHidden = false
                return
            }
            let configuration = WKWebViewConfiguration()
            // 预览不留下 cookie 和缓存。
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.add(rules)
            let web = WKWebView(frame: .zero, configuration: configuration)
            web.navigationDelegate = self
            web.wantsLayer = true
            web.layer?.cornerRadius = PanelMetrics.previewContentCornerRadius
            web.layer?.masksToBounds = true
            // 页面出来之前只显示转圈。
            web.isHidden = true
            self.view.addSubview(web, positioned: .below, relativeTo: self.spinner)
            self.webView = web
            self.view.needsLayout = true
            web.load(URLRequest(url: url, timeoutInterval: 20))
        }
    }

    /// 先确认能读再交给快速查看：没有文件夹权限时快速查看只显示英文的 “Unable to read this file.”（L114）。
    /// 真正打开一次才会触发系统的授权询问，可能阻塞，放在后台；期间换了内容就丢弃结果。
    private func showFileWhenReadable(_ url: URL) {
        fileCheckTask?.cancel()
        spinner.startAnimation(nil)
        fileCheckTask = Task { [weak self] in
            let access = await FileAccess.check([url])
            guard !Task.isCancelled, let self else { return }
            self.fileCheckTask = nil
            self.spinner.stopAnimation(nil)
            if access.denied.isEmpty {
                self.showQuickLook(url)
            } else {
                let folder = FileManager.default.displayName(atPath: FileAccess.protectedFolder(containing: url).path)
                self.fileIcon.image = NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data)
                self.fileIcon.isHidden = false
                self.unavailableTitle.stringValue = String(localized: "无法访问这个文件")
                self.unavailableDetail.stringValue = String(localized: "XPaste 没有访问“\(folder)”的权限，可在“系统设置 › 隐私与安全性 › 文件与文件夹”中允许。")
                self.unavailableTitle.isHidden = false
                self.unavailableDetail.isHidden = false
            }
            self.view.needsLayout = true
        }
    }

    private func showQuickLook(_ url: URL) {
        guard let preview = QLPreviewView(frame: .zero, style: .normal) else { return }
        preview.autostarts = false
        preview.shouldCloseWithWindow = false
        preview.previewItem = url as NSURL
        preview.wantsLayer = true
        preview.layer?.cornerRadius = PanelMetrics.previewContentCornerRadius
        preview.layer?.masksToBounds = true
        view.addSubview(preview, positioned: .below, relativeTo: spinner)
        quickLook = preview
    }

    private func analyze(_ image: NSImage) {
        guard ImageAnalyzer.isSupported else { return }
        analysisTask = Task { [weak self] in
            let analysis = try? await ImageAnalyzer().analyze(image, orientation: .up, configuration: .init([.text]))
            // 分析期间可能已经切到别的条目。
            guard !Task.isCancelled, let self, self.imageView.image === image else { return }
            self.liveText.analysis = analysis
        }
    }

    private static func iconButton(_ symbol: String, pointSize: CGFloat, label: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium)) ?? NSImage()
        let button = PreviewButton(image: image, target: nil, action: nil)
        button.isBordered = false
        button.setAccessibilityLabel(label)
        return button
    }

    @objc private func closeClicked() { onClose?() }
    @objc private func footerClicked() { onFooterAction?() }
    @objc private func shareClicked() { onShare?(shareButton) }
    @objc private func editClicked() { onEdit?() }

    @objc private func pinClicked() {
        pinMenu?()?.popUp(positioning: nil, at: NSPoint(x: 0, y: pinButton.bounds.height + 4), in: pinButton)
    }
}

extension PreviewViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // 页面里的跳转（包括重定向）同样不许去本机和内网地址。
        guard let url = navigationAction.request.url else { return .cancel }
        if url.scheme == "about" || url.scheme == "data" || url.scheme == "blob" { return .allow }
        // 每次导航（包括服务器跳转）都重新解析域名，解析到本机或内网就停下（L100）。
        return await LinkMetadataFetcher.isPublicURL(url) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        webView.isHidden = false
        spinner.stopAnimation(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        spinner.stopAnimation(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        guard webView === self.webView else { return }
        spinner.stopAnimation(nil)
        unavailableTitle.isHidden = false
        unavailableDetail.isHidden = false
    }
}
