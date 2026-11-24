import AppKit

/// 菜单栏图标。平时是模板图（随菜单栏深浅自动着色）；暂停时右下角叠一个暂停标记；采集到新内容时播一段“发牌”动画。
///
/// 图标是左小右大叠在一起的三张卡片。动画是 XPaste 自己设计的：三张卡片从后往前依次跳起、落下时轻轻回弹，
/// 最前面那张在跳起的同时翻一次面，像刚发进来一张新牌。约 0.6 秒，开启“减弱动态效果”时不播。
@MainActor
final class StatusIcon {
    private weak var button: NSStatusBarButton?
    private let base: NSImage
    private var frames: [NSImage] = []
    private var timer: Timer?
    private var frameIndex = 0

    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            if isPaused { stopAnimation() }
            if timer == nil { button?.image = still }
        }
    }

    init(button: NSStatusBarButton?) {
        self.button = button
        base = NSImage(named: "StatusIcon") ?? NSImage(systemSymbolName: "clipboard", accessibilityDescription: nil)!
        base.isTemplate = true
        button?.image = still
        button?.setAccessibilityLabel("XPaste")
    }

    private var still: NSImage { isPaused ? pausedImage : base }

    private lazy var pausedImage: NSImage = {
        let image = NSImage(size: Self.size, flipped: false) { [base] rect in
            base.draw(in: rect)
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            // 先在右下角挖一块圆角方形（照原版；挖成圆形时卡片边缘看着像缺了一块），暂停标记和卡片之间留出空隙。
            let center = CGPoint(x: 14.2, y: 4.4)
            context.setBlendMode(.destinationOut)
            context.addPath(CGPath(roundedRect: CGRect(x: center.x - 4.3, y: center.y - 4.6, width: 8.6, height: 9.2), cornerWidth: 1.6, cornerHeight: 1.6, transform: nil))
            context.fillPath()
            context.setBlendMode(.normal)
            context.setFillColor(NSColor.black.cgColor)
            for x in [center.x - 1.9, center.x + 0.5] {
                context.addPath(CGPath(roundedRect: CGRect(x: x, y: center.y - 2.8, width: 1.4, height: 5.6), cornerWidth: 0.7, cornerHeight: 0.7, transform: nil))
            }
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }()

    // MARK: 采集动画

    /// 采集到一条新内容。动画播到一半又来一条时从头再播。
    func playCapture() {
        guard !isPaused, button != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        if frames.isEmpty { frames = (0..<Self.frameCount).map { makeFrame(at: Double($0) / Double(Self.frameCount - 1)) } }
        frameIndex = 0
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func advance() {
        guard frameIndex < frames.count else { return stopAnimation() }
        button?.image = frames[frameIndex]
        frameIndex += 1
    }

    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
        button?.image = still
    }

    #if DEBUG
    var debugStill: NSImage { still }
    func debugFrames() -> [NSImage] { (0..<Self.frameCount).map { makeFrame(at: Double($0) / Double(Self.frameCount - 1)) } }
    #endif

    private static let size = NSSize(width: 18, height: 18)
    /// 动画帧比静态图高，留出向上跳的空间；按钮把图片居中放，卡片的静止位置和静态图一致。
    private static let frameSize = NSSize(width: 18, height: 24)
    private static let duration = 0.62
    private static let frameCount = Int(duration * 60)

    /// 三张卡片在 18 × 18 的图里占的横向范围（按素材量的），各自单独移动。
    private static let layers: [ClosedRange<CGFloat>] = [0...4.6, 4.6...8.3, 8.3...18]

    private func makeFrame(at progress: Double) -> NSImage {
        let time = progress * Self.duration
        let image = NSImage(size: Self.frameSize, flipped: false) { [base] _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            let originY = (Self.frameSize.height - Self.size.height) / 2
            for (index, range) in Self.layers.enumerated() {
                let local = time - Double(index) * 0.07
                context.saveGState()
                context.translateBy(x: 0, y: originY + Self.hop(local))
                if index == Self.layers.count - 1 {
                    // 最前面的卡片翻面：横向缩到侧面朝外再展开。
                    let flip = Self.flipScale(time)
                    let centerX = (range.lowerBound + 16) / 2
                    context.translateBy(x: centerX, y: 0)
                    context.scaleBy(x: flip, y: 1)
                    context.translateBy(x: -centerX, y: 0)
                }
                context.clip(to: CGRect(x: range.lowerBound, y: 0, width: range.upperBound - range.lowerBound, height: Self.size.height))
                base.draw(in: NSRect(origin: .zero, size: Self.size))
                context.restoreGState()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 一张卡片的纵向位移：0.3 秒跳起 3 点再落下，落地后回弹一次。
    private static func hop(_ t: Double) -> CGFloat {
        let air = 0.3
        guard t > 0 else { return 0 }
        if t < air { return 3 * sin(.pi * t / air) }
        let settle = t - air
        guard settle < 0.16 else { return 0 }
        return -0.7 * sin(.pi * settle / 0.16)
    }

    /// 前卡的横向缩放：0.12–0.46 秒之间翻一次，最窄时只剩一条边。
    private static func flipScale(_ t: Double) -> CGFloat {
        let start = 0.12, length = 0.34
        guard t > start, t < start + length else { return 1 }
        return max(0.06, abs(cos(.pi * (t - start) / length)))
    }
}

/// 屏幕下方居中、程序坞上方显示一下的提示（位置照原版）：玻璃圆角方块，大图标加一行说明，淡入淡出。
/// 暂停、恢复采集，以及只复制到剪贴板（没有直接粘贴）时用。
@MainActor
final class StatusHUD {
    static let shared = StatusHUD()

    private var window: NSPanel?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSButton(title: "", target: nil, action: nil)
    private var detailAction: (() -> Void)?
    private var generation = 0

    private static let side: CGFloat = 200
    /// 提示底边到程序坞上缘（没有程序坞时到屏幕底边）的距离。
    private static let bottomGap: CGFloat = 50

    #if DEBUG
    var debugWindow: NSWindow? { window }
    #endif

    func owns(_ window: NSWindow) -> Bool { window === self.window }

    /// `until` 是定时暂停的恢复时间。
    func showPause(_ paused: Bool, until: Date? = nil) {
        show(symbol: paused ? "pause" : "arrow.clockwise",
             title: paused ? String(localized: "XPaste 已暂停") : String(localized: "XPaste 已恢复"),
             detail: until.map { String(localized: "直到 \(Self.timeFormatter.string(from: $0))") })
    }

    /// 内容只放进了剪贴板。还没允许直接粘贴时下面多一行可以点的“启用直接粘贴”。
    func showCopied(offerDirectPaste: (() -> Void)?) {
        show(symbol: "checkmark", title: String(localized: "已复制"),
             detail: offerDirectPaste == nil ? nil : String(localized: "启用直接粘贴") + " ›", action: offerDirectPaste)
    }

    /// 多文件里有的不能用，只交出了能用的部分（审查 11）。
    func showSkippedFiles(_ count: Int, pasted: Bool) {
        show(symbol: "exclamationmark.triangle", title: pasted ? String(localized: "已粘贴") : String(localized: "已复制"),
             detail: String(localized: "另有 \(count) 个文件无法使用"))
    }

    private func show(symbol: String, title text: String, detail detailText: String?, action: (() -> Void)? = nil) {
        let window = self.window ?? makeWindow()
        self.window = window
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        title.stringValue = text
        detail.title = detailText ?? ""
        detail.isHidden = detailText == nil
        detail.isEnabled = action != nil
        detailAction = action
        // 只有带可点的那一行时才接收点击，平时点击穿过提示落到下面。
        window.ignoresMouseEvents = action == nil

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let bottom = max(screen.visibleFrame.minY, screen.frame.minY) + Self.bottomGap
        window.setFrameOrigin(NSPoint(x: (screen.frame.midX - Self.side / 2).rounded(), y: bottom.rounded()))
        WindowSharing.apply(to: window)

        generation += 1
        let token = generation
        if !window.isVisible { window.alphaValue = 0 }
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().alphaValue = 1
        }
        // 停留一会儿再淡出（能点的多停一会儿）；期间又来一次提示就按新的一次重新计时。
        DispatchQueue.main.asyncAfter(deadline: .now() + (action == nil ? 1.4 : 2.4)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.45
                    window.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        if self?.generation == token { window.orderOut(nil) }
                    }
                })
            }
        }
    }

    @objc private func detailClicked() {
        let action = detailAction
        generation += 1
        window?.orderOut(nil)
        action?()
    }

    private func makeWindow() -> NSPanel {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.side, height: Self.side),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // 要叠在面板（菜单栏级 24）上面，这里取弹出菜单级之上：定时暂停和恢复时面板不收起。
        window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]
        window.animationBehavior = .none
        window.title = String(localized: "XPaste 提示")

        // 照原版：深色、模糊重、不太透明的方块，圆角 22。叠在面板或任何背景上都看得清。
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.appearance = NSAppearance(named: .darkAqua)
        background.maskImage = NSImage(size: NSSize(width: 45, height: 45), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 22, yRadius: 22).fill()
            return true
        }.with { $0.capInsets = NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22); $0.resizingMode = .stretch }
        let content = background
        window.contentView = background

        icon.symbolConfiguration = .init(pointSize: 72, weight: .regular)
        // 浅色的字和图标，不随系统外观变：底色总是深的。
        let foreground = NSColor.white.withAlphaComponent(0.72)
        icon.contentTintColor = foreground
        title.font = .systemFont(ofSize: 18, weight: .medium)
        title.textColor = foreground
        title.alignment = .center
        detail.isBordered = false
        detail.font = .systemFont(ofSize: 13, weight: .medium)
        detail.contentTintColor = foreground
        detail.target = self
        detail.action = #selector(detailClicked)
        let stack = NSStackView(views: [icon, title, detail])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.setCustomSpacing(14, after: icon)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -24),
            icon.heightAnchor.constraint(equalToConstant: 96),
        ])
        return window
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

private extension NSImage {
    func with(_ configure: (NSImage) -> Void) -> NSImage {
        configure(self)
        return self
    }
}

