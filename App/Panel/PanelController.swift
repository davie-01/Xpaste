import AppKit
import ClipboardKit
import PasteCore

/// 无边框、不激活应用的面板：自己能成为 key 窗口接收键盘，但原应用保持前台。
class ClipPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 后台应用没有“编辑”菜单，文本框里的标准编辑快捷键要自己转发给第一响应者。
    /// ⌘F：第一次展开搜索，搜索中再按一次打开筛选。不论焦点在哪都要生效。
    var onSettings: (() -> Void)?
    var onCommandF: (() -> Void)?
    var onNavigationKey: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onNavigationKey?(event) == true { return true }
        if super.performKeyEquivalent(with: event) { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.keyCode == 3, let onCommandF {
            onCommandF()
            return true
        }
        if flags == .command, event.keyCode == 43, let onSettings {
            onSettings()
            return true
        }
        guard firstResponder is NSTextView else { return false }
        let action: Selector? = switch (event.charactersIgnoringModifiers?.lowercased(), flags) {
        case ("v", .command): #selector(NSText.paste(_:))
        case ("c", .command): #selector(NSText.copy(_:))
        case ("x", .command): #selector(NSText.cut(_:))
        case ("a", .command): #selector(NSText.selectAll(_:))
        case ("z", .command): Selector(("undo:"))
        case ("z", [.command, .shift]): Selector(("redo:"))
        default: nil
        }
        guard let action else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}

/// 不显示滚动条的滚动视图。集合视图换布局时会把滚动条重新打开，所以直接钉死。
final class BarelessScrollView: NSScrollView {
    override var hasHorizontalScroller: Bool { get { false } set {} }
    override var hasVerticalScroller: Bool { get { false } set {} }

    /// 为 true 时，鼠标滚轮的上下滚动当作左右滚动（设置里的“用鼠标滚轮滚动卡片”）。每次滚动时读，设置改了立即生效。
    var convertsVerticalWheel: () -> Bool = { false }

    override func scrollWheel(with event: NSEvent) {
        if convertsVerticalWheel(), let horizontal = Self.horizontalWheelEvent(from: event) {
            super.scrollWheel(with: horizontal)
        } else {
            super.scrollWheel(with: event)
        }
    }

    /// 把鼠标滚轮的上下滚动换成左右滚动：两个轴对调后交给系统照常处理，速度和方向与按住 ⇧ 滚动一样。
    /// 只换鼠标滚轮：触控板和妙控鼠标的滚动带手势阶段（phase / momentumPhase），本来就能左右滑，原样不动；
    /// 已经带横向分量的（倾斜滚轮、按着 ⇧）也不动。
    static func horizontalWheelEvent(from event: NSEvent) -> NSEvent? {
        guard event.type == .scrollWheel, event.phase.isEmpty, event.momentumPhase.isEmpty, !event.modifierFlags.contains(.shift),
              event.scrollingDeltaX == 0, event.scrollingDeltaY != 0, let cg = event.cgEvent?.copy() else { return nil }
        // 先把纵轴的三组值都读出来，再按 整数 → 定点数 → 像素 的顺序写。写定点数会重算像素位移，
        // 像素放在前面写会被冲掉：高精度滚轮（按像素计、没有手势阶段）换轴后横向位移变成 0。
        let lines = cg.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let fixed = cg.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let points = cg.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: lines)
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixed)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: points)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        return NSEvent(cgEvent: cg)
    }
}

/// 面板上缘：拖动调整高度，双击恢复默认高度，右键锁定或恢复（面板高度的全部操作都在这里，“…”菜单里另有一份）。
/// 指针移上来时整条上边框柔和地发光（`PanelEdgeGlowView`），表示可以拖；锁定时不发光，光标也不变。
final class ResizeHandleView: NSView {
    /// 参数是相对按下时的纵向位移（向上为正，取自拖动事件自身的窗口坐标）；`ended` 为 true 表示松手。
    var onDrag: ((_ delta: CGFloat, _ ended: Bool) -> Void)?
    /// 按下开始拖动（不是双击）。面板借这个时机把窗口临时向上扩展，见 `PanelController.beginHeightDrag()`。
    var onDragBegan: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    /// 锁着的时候按下了（拖动或双击）。
    var onLockedPress: (() -> Void)?
    /// 指针进出上缘、开始或结束拖动；参数是柔光该不该亮（只在悬停时亮，拖动时熄灭）。
    var onHighlight: ((Bool) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var isLocked = false {
        didSet {
            updateHighlight()
            window?.invalidateCursorRects(for: self)
            if hovering { updateCursor() }
        }
    }
    /// 现在还能往哪边拖：到了最高只能往下（向里收），到了最低只能往上（向外放）。光标的箭头跟着变。
    var directions: NSCursor.FrameResizeDirection.Set = .all {
        didSet {
            guard directions != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            if hovering || dragging { updateCursor() }
        }
    }
    private var startY: CGFloat = 0
    /// 最近一个事件相对按下时的位移；面板在拖动中被收起时用它收尾。
    private var lastDelta: CGFloat = 0
    var isDragging: Bool { dragging }
    private var dragging = false { didSet { updateHighlight() } }
    private var hovering = false { didSet { updateHighlight() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(String(localized: "面板高度"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 系统原生的窗口边缘调整光标（上下两个三角形）。
    private var resizeCursor: NSCursor { NSCursor.frameResize(position: .top, directions: directions) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    // 光标直接在指针进出、移动时设：面板不是 key 窗口时（比如焦点在预览浮层上）光标区域不起作用，
    // 以前会出现柔光亮了、光标却还是箭头，要点一下才变（用户真机）。
    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateCursor()
    }
    override func mouseMoved(with event: NSEvent) { updateCursor() }
    override func cursorUpdate(with event: NSEvent) { updateCursor() }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        if !dragging { NSCursor.arrow.set() }
    }

    private func updateCursor() {
        if isLocked { NSCursor.arrow.set() } else { resizeCursor.set() }
    }

    override func resetCursorRects() {
        if !isLocked { addCursorRect(bounds, cursor: resizeCursor) }
    }

    override func mouseDown(with event: NSEvent) {
        guard !isLocked else { onLockedPress?(); return }
        if event.clickCount == 2 {
            dragging = false
            onDoubleClick?()
            return
        }
        // 和原版一样用事件自身的窗口坐标：面板底边贴屏底不动，窗口坐标在拖动中是稳定的；
        // 不读处理时的 NSEvent.mouseLocation，那是“现在”的指针，和这个事件对不上。
        startY = event.locationInWindow.y
        lastDelta = 0
        dragging = true
        onDragBegan?()
        updateCursor()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        lastDelta = event.locationInWindow.y - startY
        onDrag?(lastDelta, false)
        // 拖动中指针会离开这条窄窄的热区，光标保持调整的样子。
        updateCursor()
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        lastDelta = event.locationInWindow.y - startY
        endDrag()
    }

    /// 结束拖动：松手和面板在拖动中被收起走同一条路（收起后松手不会再送到这里）。
    func endDrag() {
        guard dragging else { return }
        dragging = false
        onDrag?(lastDelta, true)
        // 面板已把窗口和热区恢复原样，按指针此刻是否还在上缘上决定悬停状态和光标。
        if let window {
            hovering = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
        if hovering { updateCursor() } else { NSCursor.arrow.set() }
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    /// 只有没锁定、指针悬停在上缘上时才亮；开始拖动就熄灭（拖动中柔光窗口不跟着更新），锁定时、指针不在上缘时都不亮。
    private func updateHighlight() { onHighlight?(!isLocked && hovering && !dragging) }

    #if DEBUG
    func debugHover(_ value: Bool) { hovering = value }
    #endif
}

/// 上缘可拖时的柔光：从面板上边缘往上、向面板外面散开的一片渐变光，贴着边缘最亮，往上淡到透明，左右两端也淡出，没有硬边
/// （用户真机：原先的细线加光晕太显眼；参考图是边缘处自然透出的一片光，方向是从下往上）。
final class PanelEdgeGlowView: NSView {
    /// 左右两端只在这么宽（点）的一段里淡出：大约是玻璃上角圆角的两倍，柔光基本铺满整条上缘。
    /// 以前按宽度的 12% 淡出，宽屏上两端各有两百多点在淡出，看着像中间鼓起一块（用户真机）。
    static let sideFade: CGFloat = 56
    /// 贴着面板边缘处的最高不透明度。
    static let peakAlpha: CGFloat = 0.42

    private let glow = CAGradientLayer()
    private let fade = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(glow)
        // 下亮上透：贴着面板边缘最亮，往上按高斯曲线衰减、顶边归零，色标取密一些，看不出分段。
        glow.locations = Self.verticalStops.map { NSNumber(value: Double($0.location)) }
        glow.startPoint = CGPoint(x: 0.5, y: 0)
        glow.endPoint = CGPoint(x: 0.5, y: 1)
        // 左右淡出用横向的透明度渐变做遮罩。
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        glow.mask = fade
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = bounds
        fade.frame = bounds
        // 两端淡出是固定长度，位置要按当前宽度换算。
        let stops = Self.sideStops(width: bounds.width)
        fade.locations = stops.map { NSNumber(value: Double($0.location)) }
        fade.colors = stops.map { CGColor(gray: 0, alpha: $0.alpha) }
        CATransaction.commit()
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    /// 纵向色标：`t` 从边缘（0）到顶（1），不透明度 = 峰值 × 高斯衰减 × (1 − t)，乘 (1 − t) 让顶边正好归零。
    static let verticalStops: [(location: CGFloat, alpha: CGFloat)] = (0...16).map { i in
        let t = CGFloat(i) / 16
        return (t, peakAlpha * exp(-t * t / (2 * 0.34 * 0.34)) * (1 - t))
    }

    /// 横向遮罩色标：两端各 `sideFade` 点内按 smoothstep 从 0 升到 1，中间全亮。
    static func sideStops(width: CGFloat) -> [(location: CGFloat, alpha: CGFloat)] {
        let span = min(sideFade / max(width, 1), 0.5)
        let ramp = (0...8).map { i -> (CGFloat, CGFloat) in
            let u = CGFloat(i) / 8
            return (u * span, u * u * (3 - 2 * u))
        }
        return ramp + ramp.reversed().map { (1 - $0.0, $0.1) }
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NSColor.controlAccentColor
            glow.colors = Self.verticalStops.map { accent.withAlphaComponent($0.alpha).cgColor }
        }
    }
}

/// 放柔光的透明小窗口，贴在面板上边缘的正上方。面板窗口的上边就是玻璃的上边，窗口外面画不了，所以另开一个；不接收鼠标。
@MainActor
final class PanelEdgeGlowWindow {
    /// 光往上散开的高度。留足高度，衰减才显得柔和（18 点时过渡太急，用户真机觉得硬）。
    static let depth: CGFloat = 32
    private var window: NSPanel?
    private(set) var isLit = false

    private func makeWindow() -> NSPanel {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: Self.depth), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        // 和面板同一层（菜单栏级）。
        window.level = .mainMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.animationBehavior = .none
        window.alphaValue = 0
        window.contentView = PanelEdgeGlowView()
        WindowSharing.apply(to: window)
        return window
    }

    /// `edge` 是玻璃面板在屏幕上的范围；光放在它的上边缘之上，和它一样宽。
    func follow(_ edge: NSRect) {
        window?.setFrame(NSRect(x: edge.minX, y: edge.maxY, width: edge.width, height: Self.depth), display: true)
    }

    func setLit(_ lit: Bool, along edge: NSRect) {
        guard lit != isLit else { return }
        isLit = lit
        let window = self.window ?? makeWindow()
        self.window = window
        if lit {
            follow(edge)
            window.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = lit ? 0.18 : 0.3
            window.animator().alphaValue = lit ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { if self?.isLit == false { window.orderOut(nil) } }
        })
    }
}

/// 锁定高度时挂在面板右上圆角上的锁，斜着挂。点它解锁；锁着时去拖上缘，它会晃一下。
final class PanelLockBadge: NSButton {
    static let side: CGFloat = 20
    static let tilt: CGFloat = -18

    override init(frame: NSRect) {
        super.init(frame: frame)
        image = Self.tiltedLock()
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyUpOrDown
        contentTintColor = .secondaryLabelColor
        toolTip = String(localized: "面板高度已锁定，点按解锁")
        setAccessibilityLabel(String(localized: "面板高度已锁定，点按解锁"))
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: -1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 锁的符号转一个角度画好（视图本身不转，免得和自动布局打架）。模板图，颜色跟着 `contentTintColor`。
    static func tiltedLock() -> NSImage {
        guard let symbol = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold)) else { return NSImage() }
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size, flipped: false) { rect in
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byDegrees: tilt)
            transform.concat()
            symbol.draw(in: NSRect(x: -symbol.size.width / 2, y: -symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height))
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 左右晃一下。
    func shake() {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, -3, 3, -2, 2, -1, 0]
        animation.duration = 0.4
        animation.isAdditive = true
        layer?.add(animation, forKey: "shake")
    }
}

/// 把按键先交给控制器处理的集合视图。
final class CardCollectionView: NSCollectionView {
    var keyHandler: ((NSEvent) -> Bool)?
    /// 右键点在某张卡片上时给出菜单。
    var menuHandler: ((IndexPath) -> NSMenu?)?
    /// 选中的那一条在列表里的位置。卡片区有焦点时，辅助功能的焦点落在这张卡片上。
    var focusedIndex: (() -> Int?)?
    /// 双击某张卡片。由控制器的手势处理在第二次松手时调用。
    var doubleClickHandler: ((IndexPath) -> Void)?
    /// 卡片上的鼠标手势（选中、单击、双击、起拖）交给控制器统一处理（原版 Paste 6.6.2 的做法）。
    /// 按下时返回 true 表示由控制器接管，这次按住期间的拖动和松手也交给它；返回 false 照常交给集合视图（空白处、⌃ 点按）。
    var cardMouseDown: ((NSEvent) -> Bool)?
    var cardMouseDragged: ((NSEvent) -> Bool)?
    var cardMouseUp: ((NSEvent) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        if cardMouseDown?(event) == true { return }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if cardMouseDragged?(event) == true { return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if cardMouseUp?(event) == true { return }
        super.mouseUp(with: event)
    }

    override var accessibilityFocusedUIElement: Any? {
        guard let index = focusedIndex?(), let item = item(at: IndexPath(item: index, section: 0)) else { return super.accessibilityFocusedUIElement }
        return item
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return menuHandler?(path)
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }

    /// 应用在前台时（例如设置窗口开着）“编辑”菜单会先截走 ⌘A、⌘Z 等组合，卡片区有焦点时先交给控制器。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), window?.firstResponder === self, keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class PanelController: NSObject {
    /// 主面板窗口。
    var window: NSWindow { panel }
    var onSettings: (() -> Void)?

    /// 用户选定了要粘贴的条目。面板此时已隐藏。
    /// `direct` 为 false 时只写剪贴板，不向目标应用发粘贴。
    /// 多选时是好几条，按面板上的显示顺序排列。
    var onPaste: (([ClipSummary], _ plainText: Bool, _ direct: Bool, _ target: NSRunningApplication?) -> Void)?
    /// 批量删除前的确认，参数是条数。默认弹确认框；自检里换掉。
    /// 批量删除前确认。第二个参数表示删除后还能不能撤销。
    lazy var confirmBatchDelete: (Int, Bool) -> Bool = { [weak self] in self?.askBeforeDeleting(count: $0, undoable: $1) ?? false }
    /// 更多菜单里的暂停：nil 表示一直暂停到手动恢复，否则是秒数。
    var onPause: ((TimeInterval?) -> Void)?
    /// 把这些条目（按面板顺序）加进 Stack，没开时先打开。
    var onAddToStack: (([ClipSummary]) -> Void)?
    var isStackOpen: () -> Bool = { false }
    var onResume: (() -> Void)?
    /// 供更多菜单显示当前的暂停状态。
    var pauseStatus: () -> (isPaused: Bool, until: Date?) = { (false, nil) }

    private let store: HistoryStore
    private let panel: ClipPanel
    private let collectionView = CardCollectionView()
    private let scrollView = BarelessScrollView()
    /// 提示容器：面板一直持有同一个实例，放在滚动内容里、排在第一张历史卡片之前，和卡片一起横向滚动（原版如此）。
    /// 它不是集合视图的元素，不参与历史卡片的索引、选中和方向键移动。
    private let tips = NSStackView()
    private var displayedTips: [PanelTip]?
    /// 这次面板显示期间点 × 关掉的提示。下次显示面板时清空，条件仍成立的提示重新出现。
    private var tipsClosedForThisShow: Set<PanelTip> = []
    private var tipSizeConstraints: [NSLayoutConstraint] = []
    private let layout = CardsFlowLayout()
    private var scrollHeightConstraint: NSLayoutConstraint?
    private let resizeHandle = ResizeHandleView()
    private let edgeGlow = PanelEdgeGlowWindow()
    private let lockBadge = PanelLockBadge()
    /// 拖动上缘时显示的当前高度，在工具栏左端（暂停图标之后），松手隐藏。
    private let heightLabel = NSTextField(labelWithString: "")
    private let statusStack = NSStackView()
    /// 玻璃顶边距窗口顶边的距离：平时为 0；拖上缘时窗口临时向上扩展，玻璃靠它留在原位。
    private var glassTopConstraint: NSLayoutConstraint?
    private var handleLeadingConstraint: NSLayoutConstraint?
    private var handleTrailingConstraint: NSLayoutConstraint?
    private var handleHeightConstraint: NSLayoutConstraint?
    /// 正在拖上缘时窗口临时扩展到的顶边（屏幕坐标）；不在拖时为 nil。
    private var heightDragWindowTop: CGFloat?
    private var heightAnimation: Timer?

    /// 面板高度，用户拖动上缘调整后会记住。
    private var panelHeight: CGFloat = {
        let stored = AppPreferences.shared.panelHeight
        let height = stored > 0 ? stored : PanelMetrics.windowHeight
        return min(max(height, PanelMetrics.minWindowHeight), PanelMetrics.maxWindowHeight)
    }()
    private var heightAtDragStart: CGFloat?
    private var isCompact: Bool { PanelMetrics.isCompact(windowHeight: panelHeight) }
    private let searchBar = SearchBar()
    private var searchField: NSTextField { searchBar.textField }
    private lazy var toolbar = ToolbarView(searchBar: searchBar)
    private let filterPanel = FilterPanel()
    private let preview = PreviewPopover()
    private let editor = EditorController()
    /// 编辑保存或新建之后调用，参数是变化后的条目。
    var onContentEdited: ((ClipSummary) -> Void)?
    private var filter = FilterState()
    private let emptyLabel = NSTextField(labelWithString: "")
    /// 暂停采集期间显示在面板左上角（原版如此）。
    private let pauseIndicator = NSImageView()

    private var scope: ClipQuery.Scope = .history
    /// 最近的删除，供 ⌘Z 撤销。只在内存里，退出即失效。
    private var undoStack: [[RestorableClip]] = []
    private static let undoLimit = 10
    /// 撤销要把被删条目的全部内容留在内存里，恢复时逐条重新入库。一次删除超过这些就不留副本（L102）：
    /// 实测 1 万条（含 500 张 500 KB 的图）留副本 0.65 秒、内存多 263 MB，撤销要 11 秒。
    private static let undoItemLimit = 200
    private static let undoByteLimit = 32 * 1024 * 1024
    private var renameField: NSTextField?
    private var renamingID: ClipSummary.ID?
    private var pinboards: [Pinboard] = []

    private var visibleClips: [ClipSummary] = []
    private var hasMore = false
    /// 列表每次整体重载或清空就加一。延后执行的分页加载据此判断自己是否已经过时。
    private var dataGeneration = 0
    private static let pageSize = 50
    /// 列表查询在后台执行（L45），只采用最后一次请求的结果。收起面板或发起新查询都会让旧结果作废。
    private var queryTask: Task<Void, Never>?
    /// 图片预览的原图在后台读取和解码（L09）。
    private var previewImageTask: Task<Void, Never>?
    private var queryGeneration = 0
    private var loadingMore = false
    /// 选中项按 ID 记，新内容插入时不会让选中的东西变成另一条。
    /// 多选时是最后操作的那一条：预览、编辑、重命名都针对它。直接赋值等于改成只选这一条。
    private var selectedID: ClipSummary.ID? { didSet { selectedIDs = selectedID.map { [$0] } ?? []; allSelectedIDs = nil } }
    /// ⌘A 选中的整个列表（按显示顺序），含还没加载的条目；别的选中操作都会清掉它（L33）。
    private var allSelectedIDs: [ClipSummary.ID]? { didSet { allSelectedClips = nil } }
    /// `allSelectedIDs` 对应的摘要，取一次后缓存；拖动时每张卡片都要问一次选中项。
    private var allSelectedClips: [ClipSummary]?
    /// 全部选中的条目，总是包含 `selectedID`；多于一条即多选。
    private var selectedIDs: Set<ClipSummary.ID> = []
    /// ⇧ 扩选的起点。
    private var anchorID: ClipSummary.ID?
    /// 按在卡片上、还没松手也没起拖的那一次按下。
    private var cardPress: CardPress?
    /// 上一次普通单击（没起拖）松手时的条目，第二次松手是同一条才算双击。
    private var lastClickedID: ClipSummary.ID?
    /// 正在进行的卡片拖动。每次会话一个新的来源对象，旧会话迟到的回调认得出来、不影响下一次。
    private var activeDrag: CardDragSource?
    /// 卡片手势期间被延后的后台刷新。
    private var pendingBackgroundReload = false
    private var cardGestureActive: Bool { cardPress != nil || activeDrag != nil }
    /// 唤起面板之前的前台应用，直接粘贴的目标。
    private var targetApp: NSRunningApplication?
    /// 最近一个到过前台的其他应用。设置窗口、确认框会让 XPaste 自己到前台，这时粘贴给它之前的应用。
    private var lastExternalApp: NSRunningApplication?

    /// 正在播放收起动画时也算已隐藏，再按热键会重新显示。
    var isVisible: Bool { panel.isVisible && !isHiding }
    private var isHiding = false
    /// 每次显示递增，用来丢弃上一轮动画迟到的回调。
    private var presentation = 0
    private var timeRefreshTimer: Timer?
    /// 关掉后显示和收起都立即完成。自检用；用户开启“减弱动态效果”时也走这条路径。
    var animationsEnabled = true

    private let preferences: AppPreferences

    init(store: HistoryStore, preferences: AppPreferences = .shared) {
        self.preferences = preferences
        self.store = store
        panel = ClipPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: PanelMetrics.windowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        super.init()
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApp = front
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(applicationDidActivate(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsDidChange),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        WindowSharing.apply(to: panel, preferences: preferences)
        configurePanel()
        buildContent()
    }

    // MARK: 显示与隐藏

    func toggle() {
        isVisible ? hide() : show()
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalApp = app
    }

    /// 系统的增强对比度等选项变了：开着的面板马上按新选项重画卡片。
    @objc private func displayOptionsDidChange() {
        guard isVisible else { return }
        refreshTips()
        collectionView.reloadData()
        applySelection(scroll: false)
    }

    func show() {
        let signpost = Log.signposter.beginInterval("panel.show", id: Log.signposter.makeSignpostID())
        defer { Log.signposter.endInterval("panel.show", signpost) }
        let front = NSWorkspace.shared.frontmostApplication
        targetApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? lastExternalApp : front
        // 屏幕选择先用鼠标所在屏，原版规则待实测（Docs/归档/09 M0 待答问题）。
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        // 用屏幕全尺寸而不是可用区域：面板贴屏幕底边并盖住 Dock。
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: panelHeight)
        tipsClosedForThisShow.removeAll()
        refreshTips()
        applyMetrics()
        pauseStateDidChange()

        searchField.stringValue = ""
        filter = FilterState()
        filterPanel.sync(filter)
        searchBar.setTokens([])
        toolbar.isSearching = false
        reloadPinboards()
        reload(selectFirst: true)

        presentation += 1
        isHiding = false
        idleCleanup?.invalidate()
        idleCleanup = nil
        // 上一轮收起还没结束就又打开了：那一轮的收起回调（粘贴、打开设置等）作废（审查 07）。
        hideCompletions = []
        // 与原版一样：窗口位置不动，窗口里的内容从底边以下整体滑入。
        panel.setFrame(frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(collectionView)
        slideContent(from: -frame.height, to: 0, duration: PanelMetrics.showDuration, timing: PanelMetrics.showTiming, completion: nil)
        startTimeRefresh()
    }

    /// 让窗口内容沿纵向滑动。开启“减弱动态效果”时直接到位。
    private func slideContent(from: CGFloat, to: CGFloat, duration: TimeInterval, timing: CAMediaTimingFunction, completion: (@MainActor @Sendable () -> Void)?) {
        guard animationsEnabled, let layer = panel.contentView?.layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.contentView?.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: to))
            completion?()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { Task { @MainActor in completion?() } }
        let animation = CABasicAnimation(keyPath: "transform.translation.y")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = timing
        layer.setAffineTransform(CGAffineTransform(translationX: 0, y: to))
        layer.add(animation, forKey: "slide")
        CATransaction.commit()
    }

    /// 面板可见期间定时刷新卡片上的相对时间；隐藏后停掉。
    private func startTimeRefresh() {
        timeRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: PanelMetrics.timeRefreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                self.refreshVisibleTimes()
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        timeRefreshTimer = timer
    }

    /// 只更新屏幕上卡片的相对时间（审查 14）。数据有变化时另有 `historyDidChange` 重查。
    private func refreshVisibleTimes() {
        let now = Date()
        for path in collectionView.indexPathsForVisibleItems() where visibleClips.indices.contains(path.item) {
            (collectionView.item(at: path) as? ClipCardItem)?.refreshTime(for: visibleClips[path.item], now: now)
        }
    }

    /// 收起面板。`completion` 在面板真正移出屏幕、键盘焦点回到原应用之后调用。
    /// 回调绑定在这一轮收起上：收起途中又被打开时作废，不会被下一轮收起拿走（审查 07）。
    func hide(completion: (() -> Void)? = nil) {
        // 已经在收起：排在这一轮后面，等真正收起后一起调用。
        if isHiding {
            if let completion { hideCompletions.append(completion) }
            return
        }
        guard panel.isVisible else {
            completion?()
            return
        }
        filterPanel.close()
        preview.close()
        // 拖上缘途中被收起（比如按了热键）：收起后松手不会再送到这里，现在就按松手收尾，恢复窗口范围。
        resizeHandle.endDrag()
        edgeGlow.setLit(false, along: glassScreenFrame)
        // 按住卡片时面板被收起，松手不会再送到这里；拖动会话继续，由它自己结束。
        cardPress = nil
        lastClickedID = nil
        timeRefreshTimer?.invalidate()
        timeRefreshTimer = nil
        isHiding = true
        hideCompletions = completion.map { [$0] } ?? []
        let token = presentation

        slideContent(from: 0, to: -panel.frame.height, duration: PanelMetrics.hideDuration, timing: PanelMetrics.hideTiming) { [weak self] in
            self?.finishHiding(token: token)
        }
    }

    private var hideCompletions: [() -> Void] = []

    private func finishHiding(token: Int) {
        // 收起途中又被唤起时，不要把新一轮的面板关掉；这一轮的回调在 show() 里已经作废。
        guard presentation == token, isHiding else { return }
        isHiding = false
        panel.orderOut(nil)
        // 隐藏后不保留列表数据，下次显示时重新查询；还没回来的查询结果作废。
        visibleClips = []
        dataGeneration += 1
        queryGeneration += 1
        queryTask = nil
        collectionView.reloadData()
        let completions = hideCompletions
        hideCompletions = []
        completions.forEach { $0() }
        scheduleIdleCleanup()
    }

    /// 面板收起后这么久没再打开，就放掉只为显示面板而留的内存。
    static let idleCleanupDelay: TimeInterval = 60
    private var idleCleanup: Timer?

    /// 收起一分钟后清掉解码好的缩略图（上限 64 MB）和数据库缓存（轻量化）。一分钟内再打开面板不受影响；
    /// 之后再打开时缩略图按屏幕上的卡片重新解码，数据库按需读回。
    private func scheduleIdleCleanup() {
        idleCleanup?.invalidate()
        let store = store
        let timer = Timer(timeInterval: Self.idleCleanupDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isVisible else { return }
                self.idleCleanup = nil
                ThumbnailCache.shared.removeAll()
                Task.detached(priority: .utility) { store.releaseMemory() }
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        idleCleanup = timer
    }

    #if DEBUG
    /// 自检用：立即做收起后的清理。
    func debugRunIdleCleanup() {
        idleCleanup?.fire()
    }
    var debugIdleCleanupScheduled: Bool { idleCleanup != nil }
    #endif

    /// 暂停或恢复采集之后调用。
    func pauseStateDidChange() {
        pauseIndicator.isHidden = !pauseStatus().isPaused
    }

    /// 历史变化时刷新。面板隐藏期间不做任何界面工作。
    func historyDidChange() {
        guard isVisible else { return }
        reload(selectFirst: false, background: true)
    }

    // MARK: 搭建

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // 无边框窗口不显示标题，这个标题只给 VoiceOver 读；不设的话只会读成“系统对话框”。
        panel.title = String(localized: "剪贴板历史")
        // 层级 24（菜单栏级，原版 Paste 实测也是 24）：高于程序坞（20），低于系统云团效果的窗口（25），
        // 拖拽取消时的云团才不会被面板挡住（L147）。右键菜单、弹出框、提示方块都仍在面板之上。
        panel.level = .mainMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        // 显式设 false：不设时窗口服务器按像素透明度命中，完全透明的地方鼠标落到下面的窗口。拖上缘时窗口向上扩展出的
        // 透明区域因此不算面板的，指针一进去，下面的应用就把光标改成它的（比如输入框的 I 形），面板再也设不回来（用户真机，小样复现）。
        // 设过就回不到按透明度命中，所以创建时就设：玻璃四周的透明留白（左右、底下各 8 点）也算面板的（用户决定，2026-11-24）。
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.delegate = self
    }

    private func buildContent() {
        let m = PanelMetrics.self
        let root = NSView()
        // 出入场动画作用在根视图的图层上。
        root.wantsLayer = true
        panel.contentView = root

        let glass = NSGlassEffectView()
        glass.cornerRadius = m.panelCornerRadius
        glass.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(glass)

        let content = NSView()
        glass.contentView = content

        searchField.delegate = self
        searchBar.onClear = { [weak self] in self?.clearSearch() }
        searchBar.onFilterButton = { [weak self] in self?.toggleFilterPanel() }
        filterPanel.onChange = { [weak self] in self?.filterDidChange($0) }
        filterPanel.onPick = { [weak self] in self?.focusSearch() }
        panel.onCommandF = { [weak self] in
            guard let self else { return }
            self.toolbar.isSearching ? self.toggleFilterPanel() : self.focusSearch()
        }

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.onSelectScope = { [weak self] in self?.select(scope: $0) }
        toolbar.onSearchButton = { [weak self] in self?.focusSearch() }
        toolbar.onCreatePinboard = { [weak self] in self?.createPinboard(named: $0) }
        toolbar.onMore = { [weak self] in self?.showMoreMenu(from: $0) }
        toolbar.onDropClips = { [weak self] ids, board in self?.pin(ids: ids, to: board) }
        toolbar.acceptsDrop = { [weak self] in self?.isOwnActiveDrag($0) ?? false }
        toolbar.onRenamePinboard = { [weak self] board, name in self?.rename(board, to: name) }
        toolbar.pinboardMenu = { [weak self] in self?.menu(for: $0) }
        toolbar.onEndEditing = { [weak self] in
            guard let self else { return }
            self.panel.makeFirstResponder(self.collectionView)
        }
        content.addSubview(toolbar)

        layout.scrollDirection = .horizontal

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        // 点按卡片的选中（含 ⌘、⇧）由卡片手势处理自己做，见“卡片手势”。
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = false
        // 拖动由卡片手势处理用独立的拖拽来源启动，集合视图自己不起拖；它只作为 Pinboard 排序的落点。
        collectionView.registerForDraggedTypes([ClipDrag.idsType])
        collectionView.backgroundColors = [.clear]
        collectionView.register(ClipCardItem.self, forItemWithIdentifier: ClipCardItem.identifier)
        collectionView.register(DropIndicatorView.self, forSupplementaryViewOfKind: NSCollectionView.elementKindInterItemGapIndicator,
                                withIdentifier: DropIndicatorView.identifier)
        panel.onSettings = { [weak self] in self?.onSettings?() }
        panel.onNavigationKey = { [weak self] in self?.handleNavigationKey($0) ?? false }
        collectionView.keyHandler = { [weak self] in self?.handleKey($0) ?? false }
        collectionView.menuHandler = { [weak self] in self?.contextMenu(forItemAt: $0) }
        collectionView.focusedIndex = { [weak self] in self?.selectedIndex }
        collectionView.cardMouseDown = { [weak self] in self?.cardMouseDown($0) ?? false }
        collectionView.cardMouseDragged = { [weak self] in self?.cardMouseDragged($0) ?? false }
        collectionView.cardMouseUp = { [weak self] in self?.cardMouseUp($0) ?? false }
        // 双击和回车一样：按“粘贴项目”的设置直接粘贴到应用或只放进剪贴板（原版如此）。
        collectionView.doubleClickHandler = { [weak self] path in
            guard let self, self.renameField == nil, self.visibleClips.indices.contains(path.item) else { return }
            self.closePreview()
            self.paste([self.visibleClips[path.item]], plainText: false)
        }

        preview.onKey = { [weak self] in self?.handleKey($0) ?? false }
        preview.onCloseButton = { [weak self] in self?.closePreview() }
        preview.pinMenu = { [weak self] in
            guard let self, let index = self.selectedIndex else { return nil }
            return self.pinMenu(for: [self.visibleClips[index]])
        }
        preview.onResignKey = { [weak self] in self?.hideIfFocusLeft() }
        preview.onFooterAction = { [weak self] in
            guard let self, let index = self.selectedIndex else { return }
            let clip = self.visibleClips[index]
            clip.kind == .file ? self.revealInFinder(clip) : self.open(clip)
        }
        preview.onShare = { [weak self] in self?.showSharePicker(from: $0) }
        preview.onEdit = { [weak self] in self?.editSelection() }

        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.convertsVerticalWheel = { [weak self] in self?.preferences.wheelScrollsCards ?? false }
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)
        tips.orientation = .horizontal
        tips.alignment = .top
        // 容器挂在集合视图（滚动内容）里，按帧摆放：位置和宽度在 updateTipMetrics 里与历史卡片的起点一起算。
        tips.translatesAutoresizingMaskIntoConstraints = true
        tips.autoresizingMask = []
        tips.isHidden = true
        collectionView.addSubview(tips)
        // 卡片滚动时预览浮层要跟着走。
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(cardsDidScroll), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.onDrag = { [weak self] in self?.resizePanel(by: $0, ended: $1) }
        resizeHandle.onDragBegan = { [weak self] in self?.beginHeightDrag() }
        resizeHandle.onDoubleClick = { [weak self] in self?.resetPanelHeight() }
        resizeHandle.onLockedPress = { [weak self] in self?.lockBadge.shake() }
        resizeHandle.onHighlight = { [weak self] lit in
            guard let self else { return }
            self.edgeGlow.setLit(lit && self.panel.isVisible, along: self.glassScreenFrame)
        }
        resizeHandle.menuProvider = { [weak self] in self?.panelHeightMenu() }
        resizeHandle.isLocked = preferences.panelHeightLocked
        updateResizeDirections()
        root.addSubview(resizeHandle)
        lockBadge.target = self
        lockBadge.action = #selector(lockBadgeClicked)
        lockBadge.isHidden = !preferences.panelHeightLocked
        lockBadge.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(lockBadge)
        let scrollHeight = scrollView.heightAnchor.constraint(equalToConstant: m.cardAreaHeight(windowHeight: panelHeight))
        scrollHeight.isActive = true
        scrollHeightConstraint = scrollHeight

        pauseIndicator.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: String(localized: "已暂停采集"))
        pauseIndicator.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        pauseIndicator.contentTintColor = .labelColor
        pauseIndicator.toolTip = String(localized: "已暂停采集")
        pauseIndicator.isHidden = true
        heightLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        heightLabel.textColor = .secondaryLabelColor
        heightLabel.isHidden = true
        heightLabel.setAccessibilityLabel(String(localized: "面板高度"))
        // 工具栏左端平时只有暂停时才出现的暂停图标；高度数字排在它后面，隐藏的不占位置。
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 8
        statusStack.addArrangedSubview(pauseIndicator)
        statusStack.addArrangedSubview(heightLabel)
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusStack)

        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)

        // 顶边不留边距：原版的玻璃顶到窗口上缘（对原版截图量过，工具栏中心距玻璃顶 30）。拖上缘时临时改成窗口扩展出的高度。
        let glassTop = glass.topAnchor.constraint(equalTo: root.topAnchor)
        let handleLeading = resizeHandle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m.resizeHandleInset)
        let handleTrailing = resizeHandle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m.resizeHandleInset)
        let handleHeight = resizeHandle.heightAnchor.constraint(equalToConstant: m.resizeHandleHeight)
        glassTopConstraint = glassTop
        handleLeadingConstraint = handleLeading
        handleTrailingConstraint = handleTrailing
        handleHeightConstraint = handleHeight
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m.outerMargin),
            glass.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m.outerMargin),
            glassTop,
            glass.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -m.outerMargin),

            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            // 按钮中心距窗口顶（也是玻璃顶）30（13 + 34 / 2）。
            toolbar.heightAnchor.constraint(equalToConstant: (m.toolbarButtonTop + m.toolbarButtonSize / 2) * 2),

            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            handleLeading,
            handleTrailing,
            resizeHandle.topAnchor.constraint(equalTo: root.topAnchor),
            handleHeight,
            // 锁的中心落在右上圆角的弧线附近，斜挂在角上。
            lockBadge.centerXAnchor.constraint(equalTo: glass.trailingAnchor, constant: -10),
            lockBadge.centerYAnchor.constraint(equalTo: glass.topAnchor, constant: 10),
            lockBadge.widthAnchor.constraint(equalToConstant: PanelLockBadge.side),
            lockBadge.heightAnchor.constraint(equalToConstant: PanelLockBadge.side),

            statusStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            statusStack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }

    private func refreshTips() {
        let visible = preferences.visibleTips(isTrusted: DirectPastePermission.isTrusted,
                                               loginEnabled: SettingsActions.isLoginEnabled)
            .filter { !tipsClosedForThisShow.contains($0) }
        guard displayedTips != visible else {
            // 提示没变也重画一次，系统外观或增强对比度可能在面板关着时改过。
            tips.arrangedSubviews.forEach { $0.needsDisplay = true }
            return
        }
        displayedTips = visible
        NSLayoutConstraint.deactivate(tipSizeConstraints)
        tipSizeConstraints.removeAll()
        for view in tips.arrangedSubviews { tips.removeArrangedSubview(view); view.removeFromSuperview() }
        for tip in visible {
            let view = PanelTipView(tip: tip)
            view.onDismiss = { [weak self] in
                guard let self else { return }
                self.tipsClosedForThisShow.insert(tip)
                self.refreshTips()
            }
            view.onEnable = { [weak self] in self?.enableTip(tip) }
            tips.addArrangedSubview(view)
            let side = PanelMetrics.cardSide(windowHeight: panelHeight)
            tipSizeConstraints += [view.widthAnchor.constraint(equalToConstant: side),
                                   view.heightAnchor.constraint(equalToConstant: side)]
        }
        NSLayoutConstraint.activate(tipSizeConstraints)
        tips.isHidden = visible.isEmpty
        // 容器宽度和历史卡片的起点在同一次布局更新里改。
        updateTipMetrics()
        layout.invalidateLayout()
        panel.contentView?.layoutSubtreeIfNeeded()
        tips.layoutSubtreeIfNeeded()
        collectionView.layoutSubtreeIfNeeded()
    }

    private func updateTipMetrics() {
        let side = PanelMetrics.cardSide(windowHeight: panelHeight)
        let spacing = isCompact ? PanelMetrics.compactCardSpacing : PanelMetrics.cardSpacing
        tipSizeConstraints.forEach { $0.constant = side }
        tips.spacing = spacing
        // 容器从首卡左边距处开始，宽度是提示卡片加中间的间距；没有提示时宽度为 0。
        let count = CGFloat(displayedTips?.count ?? 0)
        let width = count > 0 ? count * side + (count - 1) * spacing : 0
        tips.frame = NSRect(x: PanelMetrics.cardLeadingInset, y: PanelMetrics.cardTopInset, width: width, height: width > 0 ? side : 0)
        // 历史卡片从“容器宽度 + 一个卡片间距”之后开始；没有提示时回到正常左边距。每个单元比卡片四周各大 selectionOutset。
        var inset = layout.sectionInset
        inset.left = PanelMetrics.cardLeadingInset - PanelMetrics.selectionOutset + (width > 0 ? width + spacing : 0)
        layout.sectionInset = inset
    }

    private func enableTip(_ tip: PanelTip) {
        hide { [weak self] in
            guard let self else { return }
            if tip == .directPaste { PastePerformer.requestTrust(); return }
            do {
                if let notice = try SettingsActions.setLogin(true) { self.showTipError(notice) }
            } catch { self.showTipError(error.localizedDescription) }
        }
    }

    private func showTipError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "登录时打开")
        alert.informativeText = message
        WindowSharing.apply(to: alert.window, preferences: preferences)
        AppActivation.bringToFront()
        alert.runModal()
    }

    // MARK: 面板高度与紧凑模式

    /// 按当前面板高度更新卡片尺寸、间距和卡片区高度。
    private func applyMetrics() {
        let m = PanelMetrics.self
        let side = m.cardSide(windowHeight: panelHeight)
        let area = m.cardAreaHeight(windowHeight: panelHeight)
        let outset = m.selectionOutset
        // 每个单元比卡片四周各大 outset（留给外侧的选中描边），间距和边距相应减掉。
        let item = side + outset * 2
        let top = m.cardTopInset - outset
        layout.itemSize = NSSize(width: item, height: item)
        layout.minimumLineSpacing = (isCompact ? m.compactCardSpacing : m.cardSpacing) - outset * 2
        layout.sectionInset = NSEdgeInsets(top: top, left: m.cardLeadingInset - outset, bottom: max(0, area - item - top), right: m.cardLeadingInset - outset)
        scrollHeightConstraint?.constant = area
        updateTipMetrics()
        layout.invalidateLayout()
    }

    // MARK: 面板高度：拖动、恢复默认、锁定

    /// 按下上缘开始拖动：同一个面板窗口临时向上扩展到屏幕顶，玻璃上缘留在原位。
    /// 拖动中窗口外框不再变，只改玻璃的高度：指针一直落在本窗口扩展出的拖动区域里，整块区域都是缩放光标。
    /// 以前每个拖动事件都改窗口外框，窗口总比指针慢一帧，快拖时指针越过窗口顶边，光标在箭头和缩放之间闪（用户真机）。
    /// 透明的扩展区域能参与命中，靠的是创建面板时显式设了 `ignoresMouseEvents = false`。
    private func beginHeightDrag() {
        guard !preferences.panelHeightLocked, heightDragWindowTop == nil, let screen = panel.screen else { return }
        heightAnimation?.invalidate()
        heightAnimation = nil
        heightAtDragStart = panelHeight
        let top = screen.frame.maxY
        heightDragWindowTop = top
        var frame = panel.frame
        frame.size.height = top - frame.minY
        handleLeadingConstraint?.constant = 0
        handleTrailingConstraint?.constant = 0
        layoutGlassForHeightDrag(windowHeight: frame.height)
        panel.setFrame(frame, display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.invalidateCursorRects(for: resizeHandle)
        showHeightLabel(panelHeight)
    }

    /// 拖动中玻璃顶边让出窗口扩展出的部分；热区覆盖整块扩展区，再往下盖住原来的上缘热区。
    private func layoutGlassForHeightDrag(windowHeight: CGFloat) {
        let inset = windowHeight - panelHeight
        glassTopConstraint?.constant = inset
        handleHeightConstraint?.constant = inset + PanelMetrics.resizeHandleHeight
    }

    /// 松手（或拖动中被收起）后把窗口范围、玻璃和热区恢复原样，窗口高度等于当前面板高度。
    private func endHeightDragLayout() {
        guard heightDragWindowTop != nil else { return }
        heightDragWindowTop = nil
        glassTopConstraint?.constant = 0
        handleLeadingConstraint?.constant = PanelMetrics.resizeHandleInset
        handleTrailingConstraint?.constant = -PanelMetrics.resizeHandleInset
        handleHeightConstraint?.constant = PanelMetrics.resizeHandleHeight
        var frame = panel.frame
        frame.size.height = panelHeight
        panel.setFrame(frame, display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.invalidateCursorRects(for: resizeHandle)
    }

    private func showHeightLabel(_ height: CGFloat) {
        heightLabel.stringValue = "\(Int(height)) pt"
        heightLabel.isHidden = false
    }

    /// 拖动上缘：高度跟手，工具栏左端显示当前高度。锁定时不动。
    /// 照原版：用拖动事件自己的坐标算位移；超过最高、最低后按超出距离的平方根继续少量伸缩（超出 80 只多伸约 9），
    /// 松手恢复窗口范围，再缓动收回范围并保存。
    private func resizePanel(by delta: CGFloat, ended: Bool) {
        guard !preferences.panelHeightLocked else { return }
        heightAnimation?.invalidate()
        let start = heightAtDragStart ?? panelHeight
        heightAtDragStart = ended ? nil : start
        let m = PanelMetrics.self
        let raw = start + delta
        let stretched = raw > m.maxWindowHeight ? m.maxWindowHeight + sqrt(raw - m.maxWindowHeight).rounded()
            : raw < m.minWindowHeight ? m.minWindowHeight - sqrt(m.minWindowHeight - raw).rounded()
            : raw.rounded()
        let settled = min(max(stretched, m.minWindowHeight), m.maxWindowHeight)
        setPanelHeight(stretched)
        if ended {
            heightLabel.isHidden = true
            preferences.panelHeight = Double(settled)
            endHeightDragLayout()
            if stretched != settled { animatePanelHeight(to: settled) }
        } else {
            showHeightLabel(settled)
        }
    }

    /// 玻璃面板在屏幕上的范围（窗口左右各留 `outerMargin`，上边是玻璃顶边：平时和窗口齐平，拖上缘时窗口向上扩展了）。
    private var glassScreenFrame: NSRect {
        let frame = panel.frame
        return NSRect(x: frame.minX + PanelMetrics.outerMargin, y: frame.minY, width: frame.width - PanelMetrics.outerMargin * 2, height: panelHeight)
    }

    private func setPanelHeight(_ height: CGFloat) {
        let wasCompact = isCompact
        panelHeight = height
        updateResizeDirections()
        if heightDragWindowTop != nil {
            // 拖动中窗口外框固定，只改玻璃的高度。
            layoutGlassForHeightDrag(windowHeight: panel.frame.height)
        } else {
            var frame = panel.frame
            frame.size.height = panelHeight
            // 照原版不同步重绘，内容随下一次刷新画出。
            panel.setFrame(frame, display: false)
        }
        if edgeGlow.isLit { edgeGlow.follow(glassScreenFrame) }
        applyMetrics()
        // 跨过紧凑阈值时卡片的版式变了，需要重新配置可见的卡片。
        if wasCompact != isCompact {
            collectionView.reloadData()
            applySelection(scroll: false)
        }
    }

    /// 上缘光标的箭头：到了最高只剩向下，到了最低只剩向上。
    private func updateResizeDirections() {
        let m = PanelMetrics.self
        resizeHandle.directions = panelHeight >= m.maxWindowHeight ? .inward : panelHeight <= m.minWindowHeight ? .outward : .all
    }

    var canResetPanelHeight: Bool { !preferences.panelHeightLocked && panelHeight != PanelMetrics.windowHeight }

    /// 双击上缘或从菜单恢复默认高度，0.2 秒缓动过去。锁定时不动，锁晃一下。
    func resetPanelHeight() {
        guard !preferences.panelHeightLocked else { lockBadge.shake(); return }
        let target = PanelMetrics.windowHeight
        preferences.panelHeight = Double(target)
        animatePanelHeight(to: target)
    }

    /// 0.2 秒缓动到目标高度（面板没显示或开了“减弱动态效果”时直接到位）。只改面板，不改偏好。
    private func animatePanelHeight(to target: CGFloat) {
        heightAnimation?.invalidate()
        heightAnimation = nil
        guard panelHeight != target else { return }
        guard panel.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            setPanelHeight(target)
            return
        }
        let from = panelHeight
        let begin = Date()
        let duration = 0.2
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = min(Date().timeIntervalSince(begin) / duration, 1)
                let eased = 1 - pow(1 - t, 3)
                self.setPanelHeight((from + (target - from) * eased).rounded())
                if t >= 1 {
                    self.heightAnimation?.invalidate()
                    self.heightAnimation = nil
                    self.setPanelHeight(target)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heightAnimation = timer
    }

    func togglePanelHeightLock() {
        preferences.panelHeightLocked.toggle()
        let locked = preferences.panelHeightLocked
        resizeHandle.isLocked = locked
        lockBadge.isHidden = !locked
        // 挂上去的时候晃一下，让人看见锁在哪。
        if locked { lockBadge.shake() }
    }

    @objc private func lockBadgeClicked() { togglePanelHeightLock() }

    /// 上缘右键菜单和“…”菜单共用的两项。
    private func panelHeightItems() -> [NSMenuItem] {
        let lock = ClosureMenuItem(String(localized: "锁定面板高度")) { [weak self] in self?.togglePanelHeightLock() }
        lock.state = preferences.panelHeightLocked ? .on : .off
        let reset = ClosureMenuItem(String(localized: "恢复默认高度（\(Int(PanelMetrics.windowHeight)) pt）")) { [weak self] in self?.resetPanelHeight() }
        reset.isEnabled = canResetPanelHeight
        return [lock, reset]
    }

    private func panelHeightMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        panelHeightItems().forEach(menu.addItem)
        return menu
    }

    // MARK: 数据与选中

    /// 重新查询列表。查询在后台执行，结果回到主线程时如果已有更新的请求就丢弃。
    /// `scrollToSelection` 用于撤销删除这类需要在新数据到来后把选中项滚进视野的场合。
    /// `background` 是历史变化、定时刷新这类不是用户操作引起的刷新：卡片手势进行中（按住或拖动中）时延后到手势结束，
    /// 免得按下的卡片在起拖前被重载。
    private func reload(selectFirst: Bool, scrollToSelection: Bool = false, background: Bool = false) {
        if background, cardGestureActive {
            pendingBackgroundReload = true
            return
        }
        queryGeneration += 1
        let generation = queryGeneration
        // 刷新时保持已加载的条数，避免滚动位置跳回开头。
        let count = selectFirst ? Self.pageSize : max(visibleClips.count, Self.pageSize)
        let query = currentQuery()
        let store = store
        queryTask = Task { [weak self] in
            let fetched = await Self.fetch(store: store, query: query, limit: count + 1, offset: 0)
            guard let self, generation == self.queryGeneration else { return }
            self.queryTask = nil
            // 查询途中用户按下了卡片：结果作废，手势结束后重查。
            if background, self.cardGestureActive {
                self.pendingBackgroundReload = true
                return
            }
            self.apply(fetched, count: count, selectFirst: selectFirst, scroll: selectFirst || scrollToSelection)
        }
    }

    private func apply(_ fetched: [ClipSummary], count: Int, selectFirst: Bool, scroll: Bool) {
        let applyStarted = CACurrentMediaTime()
        defer { lastApplyDuration = CACurrentMediaTime() - applyStarted }
        hasMore = fetched.count > count
        let old = visibleClips
        visibleClips = Array(fetched.prefix(count))
        dataGeneration += 1
        // 删除后的这次刷新：先按旧布局算好删除后选中的那张要滚到哪里（卡片等宽，新旧布局里同一序号的位置相同）。
        let anchor = selectFirst ? nil : pendingDeleteAnchor
        pendingDeleteAnchor = nil
        let target = anchor.flatMap { deleteScrollTarget(for: $0) }
        let current = scrollView.contentView.bounds.origin.x
        // 视口不用挪时，被删的卡片收起、后面的滑过来；要挪时不加动画，免得卡片从视口外一路扫过来。
        let animated = target.map { abs($0 - current) < 0.5 } ?? false
        if selectFirst || !updateIncrementally(from: old, to: visibleClips, animated: animated) { collectionView.reloadData() }
        if let target, abs(target - current) >= 0.5 {
            collectionView.layoutSubtreeIfNeeded()
            scrollView.contentView.scroll(to: NSPoint(x: target, y: scrollView.contentView.bounds.origin.y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        emptyLabel.isHidden = !visibleClips.isEmpty
        let isFiltering = !searchField.stringValue.isEmpty || !filter.isEmpty
        emptyLabel.stringValue = isFiltering ? String(localized: "无结果") : (scope == .history ? String(localized: "历史记录为空") : String(localized: "Pinboard 为空"))
        searchBar.refreshClearButton()

        let keptAll = selectFirst ? nil : allSelectedIDs
        if selectFirst || !visibleClips.contains(where: { $0.id == selectedID }) {
            selectedID = visibleClips.first?.id
            anchorID = selectedID
        }
        if let keptAll {
            // 整表选中时只是刷新：保持全选，删掉的条目在取选中项时自然跳过。
            allSelectedIDs = keptAll
            selectedIDs = Set(keptAll).union(selectedID.map { [$0] } ?? [])
        } else {
            // 多选里已经不在列表中的条目去掉。
            selectedIDs.formIntersection(visibleClips.map(\.id))
            if let selectedID { selectedIDs.insert(selectedID) }
        }
        applySelection(scroll: scroll)
        // 换了列表或搜索条件就收起预览；只是刷新则让浮层跟着选中项。
        if selectFirst { preview.close() } else { updatePreview() }
    }

    /// 刷新时只动变化的卡片（轻量化）：列表没变只是有几条内容更新（链接标题、改名等），开头多了几条新复制的，
    /// 或者中间删掉了几条（末尾由后面没加载的补上），就局部插入、删除和重配；别的情况（排序变化等）返回 false，由调用方整表重载。
    private func updateIncrementally(from old: [ClipSummary], to new: [ClipSummary], animated: Bool = false) -> Bool {
        guard !old.isEmpty, collectionView.numberOfSections == 1, collectionView.numberOfItems(inSection: 0) == old.count else { return false }
        let oldIDs = old.map(\.id), newIDs = new.map(\.id)
        // 开头新增了几条：新列表去掉开头这几条后，是旧列表的开头部分。
        guard let added = (0...min(new.count, 20)).first(where: { k in
            let rest = newIDs.dropFirst(k)
            return rest.count <= oldIDs.count && rest.elementsEqual(oldIDs.prefix(rest.count))
        }) else { return updateRemovals(from: old, to: new, animated: animated) }
        let kept = new.count - added
        let removedTail = old.count - kept
        let changed = (0..<kept).filter { old[$0] != new[added + $0] }.map { IndexPath(item: added + $0, section: 0) }
        guard added > 0 || removedTail > 0 || !changed.isEmpty else { return true }
        collectionView.performBatchUpdates {
            if removedTail > 0 { collectionView.deleteItems(at: Set((kept..<old.count).map { IndexPath(item: $0, section: 0) })) }
            if added > 0 { collectionView.insertItems(at: Set((0..<added).map { IndexPath(item: $0, section: 0) })) }
        }
        // 位置变了的旧卡片由批量更新挪过去；内容有变化的再按新数据重配。
        if !changed.isEmpty { collectionView.reloadItems(at: Set(changed)) }
        return true
    }

    /// 中间删掉了几条：新列表按顺序是旧列表去掉若干条，后面可能接上几条原来没加载的。只删掉那几张卡片、在末尾补上新的。
    private func updateRemovals(from old: [ClipSummary], to new: [ClipSummary], animated: Bool) -> Bool {
        var removed: [IndexPath] = []
        var changed: [IndexPath] = []
        var next = 0
        for (index, clip) in old.enumerated() {
            if next < new.count, new[next].id == clip.id {
                if new[next] != clip { changed.append(IndexPath(item: next, section: 0)) }
                next += 1
            } else {
                removed.append(IndexPath(item: index, section: 0))
            }
        }
        // 末尾接上的必须是原来没有的条目；删掉的条目也不能换个位置又出现（那是排序变了）。
        let oldIDs = Set(old.map(\.id))
        guard !removed.isEmpty, !new[next...].contains(where: { oldIDs.contains($0.id) }) else { return false }
        let appended = Set((next..<new.count).map { IndexPath(item: $0, section: 0) })
        let updates = {
            self.collectionView.deleteItems(at: Set(removed))
            if !appended.isEmpty { self.collectionView.insertItems(at: appended) }
        }
        if animated { collectionView.animator().performBatchUpdates(updates) } else { collectionView.performBatchUpdates(updates) }
        // 集合视图手里还有不在当前视口里的旧卡片时（滚动后还没显示过一次，卡片没按新视口重铺），批量删除不会挪动它们，
        // 它们留在原来的序号上、显示删除前那一条，滚回去就露出来（自检复现：卡片 9 仍显示删除前的第 9 条）。
        // 删除后逐张核对已生成的卡片，和所在序号的数据对不上的按新数据重配。
        let stale = collectionView.visibleItems().compactMap { item -> IndexPath? in
            guard let card = item as? ClipCardItem, let path = collectionView.indexPath(for: item), new.indices.contains(path.item) else { return nil }
            return card.clipID == new[path.item].id ? nil : path
        }
        let reconfigure = Set(changed).union(stale)
        if !reconfigure.isEmpty { collectionView.reloadItems(at: reconfigure) }
        return true
    }

    /// 删除后让选中的那张（被删那一段后面紧接着的一张）回到被删卡片原来在视口里的位置，眼前还是原来那一带。
    private struct DeleteAnchor {
        let id: ClipSummary.ID
        /// 删除前屏幕上第一张被删卡片的左边相对视口左边的距离；被删的一张都不在眼前时为 nil，放到视口左端。
        let offset: CGFloat?
    }
    private var pendingDeleteAnchor: DeleteAnchor?
    /// 最近一次应用查询结果（含卡片的局部更新或整表重载）在主线程上用的时间，自检量删除是否卡顿用。
    private var lastApplyDuration: CFTimeInterval = 0

    /// 卡片单元（含选中描边的外扩）在视口左端时的左边距。
    private var leadingCellInset: CGFloat { PanelMetrics.cardLeadingInset - PanelMetrics.selectionOutset }

    /// 删除前调用：记下第一张在眼前的被删卡片的位置，限制在视口里能完整看到一张卡片的范围内。
    private func deleteAnchorOffset(for indexes: [Int]) -> CGFloat? {
        let visible = scrollView.contentView.bounds
        for index in indexes {
            guard let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { continue }
            if frame.minX >= visible.maxX { break }
            guard frame.maxX > visible.minX else { continue }
            let offset = frame.minX - visible.minX
            return min(max(offset, leadingCellInset), max(leadingCellInset, visible.width - frame.width - leadingCellInset))
        }
        return nil
    }

    /// 按当前布局算出删除后视口的横向位置。卡片等宽，序号相同的卡片在删除前后的布局里位置一样，所以删除前就能算。
    /// 选中的是第一条时回到最左边，前面的提示卡片也露出来（和 `applySelection` 一致）。
    private func deleteScrollTarget(for anchor: DeleteAnchor) -> CGFloat? {
        guard let index = visibleClips.firstIndex(where: { $0.id == anchor.id }) else { return nil }
        guard index > 0 else { return 0 }
        let count = collectionView.numberOfSections == 1 ? collectionView.numberOfItems(inSection: 0) : 0
        guard index < count, visibleClips.count <= count,
              let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame,
              let last = collectionView.layoutAttributesForItem(at: IndexPath(item: visibleClips.count - 1, section: 0))?.frame else { return nil }
        let width = scrollView.contentView.bounds.width
        let contentWidth = last.maxX + layout.sectionInset.right
        return min(max(frame.minX - (anchor.offset ?? leadingCellInset), 0), max(0, contentWidth - width))
    }

    private func currentQuery() -> ClipQuery {
        var query = ClipQuery(scope: scope, text: searchField.stringValue)
        filter.apply(to: &query)
        return query
    }

    nonisolated private static func fetch(store: HistoryStore, query: ClipQuery, limit: Int, offset: Int) async -> [ClipSummary] {
        await Task.detached(priority: .userInitiated) {
            do {
                return try Log.measure("query") { try store.clips(matching: query, limit: limit, offset: offset) }
            } catch {
                Log.panel.error("查询历史失败: \(String(describing: error))")
                return []
            }
        }.value
    }

    /// 等列表查询回来再执行：搜索后立即按回车、⌘数字等，作用的必须是新结果而不是旧列表。
    /// 等待期间面板收起或重开了，这次按键作废（审查 07）。
    private func afterQuery(_ action: @escaping () -> Void) {
        guard queryTask != nil else { action(); return }
        let token = presentation
        Task { [weak self] in
            while let task = self?.queryTask { await task.value }
            guard let self, self.presentation == token, self.isVisible, !self.isHiding else { return }
            action()
        }
    }

    /// 滚动或选中接近末尾时加载下一页，同样在后台查询。
    private func loadMoreIfNeeded(near index: Int) {
        // 集合视图里的条目数必须和数据一致才能做增量插入，否则会抛异常。
        guard hasMore, !loadingMore, queryTask == nil, index >= visibleClips.count - 10,
              collectionView.numberOfSections == 1, collectionView.numberOfItems(inSection: 0) == visibleClips.count else { return }
        loadingMore = true
        let generation = queryGeneration
        let start = visibleClips.count
        let query = currentQuery()
        let store = store
        Task { [weak self] in
            let fetched = await Self.fetch(store: store, query: query, limit: Self.pageSize + 1, offset: start)
            guard let self else { return }
            self.loadingMore = false
            // 等待期间列表被重载或改变过，这一页就不再适用。
            guard generation == self.queryGeneration, self.visibleClips.count == start,
                  self.collectionView.numberOfItems(inSection: 0) == start else { return }
            self.hasMore = fetched.count > Self.pageSize
            let known = Set(self.visibleClips.map(\.id))
            let page = fetched.prefix(Self.pageSize).filter { !known.contains($0.id) }
            guard !page.isEmpty else { return }
            self.visibleClips.append(contentsOf: page)
            self.collectionView.insertItems(at: Set((start..<self.visibleClips.count).map { IndexPath(item: $0, section: 0) }))
            // 整表选中时，新加载的卡片也显示为选中。
            if self.allSelectedIDs != nil { self.applySelection(scroll: false) }
        }
    }

    /// 删除选中的条目。多选时先确认（原版实测：单条不确认，多条确认）；一次删除的几条在撤销时一起回来。
    private func deleteSelection() {
        let clips = selectedClips
        guard !clips.isEmpty else { return }
        let undoable = clips.count <= Self.undoItemLimit && clips.reduce(0, { $0 + $1.byteCount }) <= Self.undoByteLimit
        if clips.count > 1, !confirmBatchDelete(clips.count, undoable) { return }
        let ids = clips.map(\.id)
        // 删除后选中原位置上的下一张：最后一条选中项后面的那张，没有就取第一条选中项前面的。
        let indexes = visibleClips.indices.filter { selectedIDs.contains(visibleClips[$0].id) }
        var neighbor: ClipSummary.ID?
        if let last = indexes.last, visibleClips.indices.contains(last + 1) {
            neighbor = visibleClips[last + 1].id
        } else if let first = indexes.first, first > 0 {
            neighbor = visibleClips[first - 1].id
        }
        let anchorOffset = deleteAnchorOffset(for: indexes)
        do {
            // 先留一份完整副本供撤销；删除成功后才放进撤销栈，删除失败不留下无效的撤销记录（审查 04）。
            let saved = undoable ? try store.restorable(ids: ids) : []
            // 历史里删除已固定的条目只把它移出历史；Pinboard 里删除则整条删除。
            if case .pinboard = scope {
                try store.deleteFromPinboard(ids: ids)
            } else {
                try store.removeFromHistory(ids: ids)
            }
            if !saved.isEmpty {
                undoStack.append(saved)
                if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
            }
        } catch {
            Log.storage.error("删除失败: \(String(describing: error))")
            NSSound.beep()
            return
        }
        selectedID = neighbor
        anchorID = neighbor
        pendingDeleteAnchor = neighbor.map { DeleteAnchor(id: $0, offset: anchorOffset) }
        reload(selectFirst: false)
    }

    private func askBeforeDeleting(count: Int, undoable: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "删除所选的 \(count) 项？")
        if !undoable { alert.informativeText = String(localized: "所选内容较多，删除后无法撤销。") }
        alert.addButton(withTitle: String(localized: "删除"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.buttons.first?.hasDestructiveAction = true
        WindowSharing.apply(to: alert.window, preferences: preferences)
        // 确认框会抢走 key 窗口，期间不要因为失焦而关掉面板。
        suppressHideOnResign = true
        let response = alert.runModal(defaultButton: 0, cancelButton: 1)
        suppressHideOnResign = false
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(collectionView)
        return response == .alertFirstButtonReturn
    }

    /// 整批恢复成功后才从撤销栈里拿掉；失败时这一批留在栈里，可以再按 ⌘Z 重试（审查 04）。
    private func undoDelete() {
        guard let saved = undoStack.last else { NSSound.beep(); return }
        do {
            let ids = try store.restore(saved)
            undoStack.removeLast()
            selectedID = ids.first
            reload(selectFirst: false, scrollToSelection: true)
        } catch {
            Log.storage.error("撤销删除失败: \(String(describing: error))")
            NSSound.beep()
        }
    }

    // MARK: 筛选

    private func toggleFilterPanel() {
        if filterPanel.isVisible {
            filterPanel.close()
        } else {
            let apps = (try? store.sourceApps()) ?? []
            filterPanel.show(above: searchBar.filterAnchor, bar: searchBar, in: panel, state: filter, apps: apps, pinboards: pinboards)
        }
    }

    private func filterDidChange(_ state: FilterState) {
        filter = state
        searchBar.setTokens(filterPanel.tokens())
        reload(selectFirst: true)
    }

    private func clearSearch() {
        searchField.stringValue = ""
        filter = FilterState()
        filterPanel.sync(filter)
        searchBar.setTokens([])
        reload(selectFirst: true)
    }

    // MARK: 右键菜单与条目操作

    private func contextMenu(forItemAt path: IndexPath) -> NSMenu? {
        guard visibleClips.indices.contains(path.item) else { return nil }
        let clip = visibleClips[path.item]
        // 右键点在多选的某一条上时保留多选，菜单对全部选中项生效；点在别处则改选那一条。
        if !selectedIDs.contains(clip.id) || selectedIDs.count == 1 {
            selectedID = clip.id
            anchorID = clip.id
            applySelection(scroll: false)
        }

        // 多选时菜单和单选一样（Docs/归档/调研/08 第 9.16 节，L19、L20）：粘贴、复制、删除、固定、分享作用于全部选中项，其余作用于点中的这一条。
        let clips = selectedIDs.count > 1 ? selectedClips : [clip]
        let menu = NSMenu()
        let targetName = targetApp?.localizedName ?? String(localized: "当前应用")
        let plainModifier = preferences.keyboardSettings.plainText.flags
        // 原版把打开和在 Finder 中显示放在最上面一组。
        if clip.kind == .link || clip.kind == .file {
            let target = clip.kind == .file ? existingFiles(of: clip).first : URL(string: clip.previewText.trimmingCharacters(in: .whitespacesAndNewlines))
            let opener = target.flatMap { NSWorkspace.shared.defaultApplicationName(for: $0) }
            let title = opener.map { String(localized: "使用 \($0) 打开") } ?? String(localized: "打开")
            menu.addItem(ClosureMenuItem(title) { [weak self] in self?.open(clip) }.shortcut("o", .command))
            if clip.kind == .file {
                menu.addItem(ClosureMenuItem(String(localized: "在 Finder 中显示")) { [weak self] in self?.revealInFinder(clip) })
            }
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem(String(localized: "粘贴到 \(targetName)")) { [weak self] in self?.paste(clips, plainText: false) }.shortcut("\r"))
        menu.addItem(ClosureMenuItem(String(localized: "以纯文本粘贴")) { [weak self] in self?.paste(clips, plainText: true) }.shortcut("\r", plainModifier))
        menu.addItem(ClosureMenuItem(String(localized: "复制")) { [weak self] in self?.paste(clips, plainText: false, direct: false) }.shortcut("c", .command))
        menu.addItem(stackMenuItem(for: clips))
        menu.addItem(.separator())
        if [.text, .link, .color, .image].contains(clip.kind) {
            menu.addItem(ClosureMenuItem(String(localized: "编辑")) { [weak self] in self?.edit(clip) }.shortcut("e", .command))
        }
        menu.addItem(ClosureMenuItem(String(localized: "重命名")) { [weak self] in self?.beginRenaming(clip) }.shortcut("r", .command))
        menu.addItem(ClosureMenuItem(String(localized: "删除")) { [weak self] in self?.deleteSelection() }.shortcut("\u{8}"))
        menu.addItem(.separator())

        let pin = NSMenuItem(title: String(localized: "固定"), action: nil, keyEquivalent: "")
        pin.submenu = pinMenu(for: clips, includesUnpin: false)
        menu.addItem(pin)
        if clips.contains(where: { $0.listID != nil }) {
            menu.addItem(ClosureMenuItem(String(localized: "取消固定")) { [weak self] in self?.unpin(clips) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(String(localized: "预览")) { [weak self] in self?.showPreview() }.shortcut(" "))
        // “分享”是列出各个服务的二级菜单，服务按内容类型不同（原版如此，L111）。系统的 standardShareMenuItem
        // 在 macOS 27 上点了会另弹分享选择器，不是二级菜单。选了某个服务后面板会因为失去焦点自己收起。
        let items = clips.flatMap { shareItems(for: $0) }
        let services = Self.sharingServices(for: items)
        if !services.isEmpty {
            let share = NSMenuItem(title: String(localized: "分享"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for service in services {
                let item = ClosureMenuItem(service.menuItemTitle) { service.perform(withItems: items) }
                item.setVisibleImage(service.image)
                submenu.addItem(item)
            }
            share.submenu = submenu
            menu.addItem(share)
        }
        return menu
    }

    // MARK: 编辑与新建

    private func editSelection() {
        guard let index = selectedIndex else { return }
        edit(visibleClips[index])
    }

    /// 打开编辑窗口，面板同时收起。保存后条目留在原来的位置，时间不变（原版实测）。
    private func edit(_ clip: ClipSummary) {
        let content: EditorContent
        switch clip.kind {
        case .text where clip.byteCount > Self.inlineTextLimit:
            // 大段文字先在后台读出再打开编辑窗口。
            loadText(of: clip) { [weak self] text, rich in
                guard let self, self.isVisible else { return }
                self.openEditor(rich.map { EditorContent.text($0, isRich: true) } ?? .text(NSAttributedString(string: text), isRich: false), for: clip)
            }
            return
        case .text:
            guard let snapshot = try? store.snapshot(id: clip.id) else { NSSound.beep(); return }
            if let rtf = snapshot.items.first?.data(for: ClipType.rtf), let rich = NSAttributedString(rtf: rtf, documentAttributes: nil) {
                content = .text(rich, isRich: true)
            } else {
                content = .text(NSAttributedString(string: snapshot.plainText ?? clip.previewText), isRich: false)
            }
        case .link:
            content = .link(((try? store.snapshot(id: clip.id))?.plainText ?? clip.previewText).trimmingCharacters(in: .whitespacesAndNewlines))
        case .color:
            let hex = clip.previewText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            content = .color(hex.hasPrefix("#") ? hex : "#" + hex)
        case .image:
            guard let data = (try? store.imageData(id: clip.id)) ?? nil, let image = ImageEditing.decode(data) else { NSSound.beep(); return }
            content = .image(image)
        case .file, .unknown:
            // 文件和未知类型不能编辑。
            NSSound.beep()
            return
        }
        openEditor(content, for: clip)
    }

    private func openEditor(_ content: EditorContent, for clip: ClipSummary) {
        let screen = panel.screen
        hide { [weak self] in
            self?.editor.open(content, on: screen) { result in
                guard let self, let result else { return }
                try self.save(result, to: clip)
            }
        }
    }

    /// 写库失败时抛给编辑窗口，窗口留着让用户重试（审查 15）。条目已被删掉时不算失败，直接关窗口。
    private func save(_ result: EditorResult, to clip: ClipSummary) throws {
        let snapshot = Self.snapshot(from: result, sourceBundleID: clip.sourceBundleID, sourceName: clip.sourceName)
        do {
            guard let updated = try store.replaceContent(of: clip.id, with: snapshot) else { return }
            ThumbnailCache.shared.remove(id: updated.id)
            onContentEdited?(updated)
        } catch {
            Log.storage.error("保存编辑失败: \(String(describing: error))")
            throw error
        }
    }

    /// 新文本项：创建到当前所在的列表。在 Pinboard 里新建的同时固定到它。
    func newTextItem() {
        let screen = panel.screen
        let scope = scope
        hide { [weak self] in
            self?.editor.open(.newText, on: screen) { result in
                guard let self, let result else { return }
                let snapshot = Self.snapshot(from: result, sourceBundleID: Bundle.main.bundleIdentifier, sourceName: "XPaste")
                // 进历史；在 Pinboard 里新建的同时固定到它。失败时编辑窗口留着（审查 15）。
                let created: ClipSummary
                do {
                    created = try self.store.record(snapshot)
                    if case .pinboard(let id) = scope { try self.store.pin(ids: [created.id], to: id) }
                } catch {
                    Log.storage.error("新建文本项失败: \(String(describing: error))")
                    throw error
                }
                self.onContentEdited?(created)
                // 原版创建后重新显示面板，新条目排在最前并被选中（M5 第 7 步实测）。
                self.show()
            }
        }
    }

    /// 编辑结果只留纯文本和（带格式时的）RTF，图片只留 PNG；原来的其他表示已经和内容对不上，不保留。
    private static func snapshot(from result: EditorResult, sourceBundleID: String?, sourceName: String?) -> ClipSnapshot {
        var representations: [ClipRepresentation]
        switch result {
        case .text(let plain, let rtf):
            representations = [ClipRepresentation(type: ClipType.plainText, data: Data(plain.utf8))]
            if let rtf { representations.append(ClipRepresentation(type: ClipType.rtf, data: rtf)) }
        case .link(let text), .color(let text):
            representations = [ClipRepresentation(type: ClipType.plainText, data: Data(text.utf8))]
        case .image(let png):
            representations = [ClipRepresentation(type: ClipType.png, data: png)]
        }
        return ClipSnapshot(items: [ClipItemSnapshot(representations: representations)], sourceBundleID: sourceBundleID, sourceName: sourceName)
    }

    // MARK: 打开与分享

    /// 链接用默认浏览器打开，文件用各自的默认应用打开。
    private func open(_ clip: ClipSummary) {
        if clip.kind == .file {
            withAccessibleFiles(of: clip) { urls in urls.forEach { NSWorkspace.shared.open($0) } }
            return
        }
        guard let url = URL(string: clip.previewText.trimmingCharacters(in: .whitespacesAndNewlines)) else { NSSound.beep(); return }
        hide { NSWorkspace.shared.open(url) }
    }

    private func revealInFinder(_ clip: ClipSummary) {
        withAccessibleFiles(of: clip) { NSWorkspace.shared.activateFileViewerSelecting($0) }
    }

    /// 收起面板后检查文件，能访问的交给 `action`；一个都用不了时说明是已不存在还是没有权限（L14），不只响一声。
    /// 检查会真正打开文件，受保护文件夹里的文件这时会触发系统的授权询问。
    private func withAccessibleFiles(of clip: ClipSummary, _ action: @escaping ([URL]) -> Void) {
        let urls = clip.filePaths.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { NSSound.beep(); return }
        hide {
            Task { @MainActor in
                let access = await FileAccess.check(urls)
                let usable = urls.filter { !access.unusable.contains($0) }
                if usable.isEmpty { FileAccess.presentFailure(access, opening: true) } else { action(usable) }
            }
        }
    }

    private func existingFiles(of clip: ClipSummary) -> [URL] {
        clip.filePaths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 交给系统分享的内容：链接是地址，文件是文件本身，图片是图像，其余是纯文本。
    private func shareItems(for clip: ClipSummary) -> [Any] {
        switch clip.kind {
        case .file:
            return existingFiles(of: clip)
        case .image:
            return ((try? store.imageData(id: clip.id)) ?? nil).flatMap { NSImage(data: $0) }.map { [$0] } ?? []
        case .link:
            let text = clip.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
            return [URL(string: text) as Any? ?? text]
        case .text, .color, .unknown:
            return ((try? store.snapshot(id: clip.id))?.plainText).map { [$0] } ?? []
        }
    }

    /// 能分享这些内容的服务。这个接口已标为弃用、建议改用 standardShareMenuItem，但后者给不出二级菜单（见上），只能用它。
    private static func sharingServices(for items: [Any]) -> [NSSharingService] {
        items.isEmpty ? [] : NSSharingService.sharingServices(forItems: items)
    }

    /// 预览顶栏的分享按钮。分享菜单会抢走键盘焦点，期间面板不收起。
    private func showSharePicker(from anchor: NSView) {
        guard let index = selectedIndex else { return }
        let items = shareItems(for: visibleClips[index])
        guard !items.isEmpty else { NSSound.beep(); return }
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self
        sharePicker = picker
        suppressHideOnResign = true
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    private var sharePicker: NSSharingServicePicker?

    /// 各 Pinboard 加“创建 Pinboard...”。右键菜单的“固定”子菜单和预览顶栏的固定按钮共用。
    private func pinMenu(for clips: [ClipSummary], includesUnpin: Bool = true) -> NSMenu {
        let menu = NSMenu()
        // 只选了一条时不列它已经在的那个 Pinboard。
        let current = clips.count == 1 ? clips[0].listID : nil
        for board in pinboards where board.id != current {
            let item = ClosureMenuItem(board.name) { [weak self] in self?.pin(clips, to: board) }
            item.setVisibleImage(Self.dotImage(NSColor(hex: board.colorHex) ?? .systemYellow))
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem(String(localized: "创建 Pinboard...")) { [weak self] in
            self?.preview.close()
            self?.toolbar.beginCreatingPinboard()
        })
        if includesUnpin, clips.contains(where: { $0.listID != nil }) {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(String(localized: "取消固定")) { [weak self] in self?.unpin(clips) })
        }
        return menu
    }

    // MARK: 预览

    private func togglePreview() {
        preview.isShown ? closePreview() : showPreview()
    }

    private func showPreview() {
        guard renameField == nil, let index = selectedIndex else { return }
        let path = IndexPath(item: index, section: 0)
        // 卡片要完整露在屏幕里，浮层才有地方锚定。
        collectionView.scrollToItems(at: [path], scrollPosition: .nearestVerticalEdge)
        guard let rect = previewAnchor(forItemAt: index) else { return }
        let clip = visibleClips[index]
        // 大段文字先在后台读出、解析好富文本再弹出（轻量化：不在主线程上读几 MB 的内容）；小的照旧立即显示。
        if clip.kind == .text, clip.byteCount > Self.inlineTextLimit {
            loadText(of: clip) { [weak self] text, rich in
                guard let self, self.isVisible, self.selectedID == clip.id, let index = self.selectedIndex,
                      let rect = self.previewAnchor(forItemAt: index) else { return }
                self.preview.show(clip: clip, content: .text(text, rich: rich), relativeTo: rect, of: self.collectionView)
                if !self.panel.isKeyWindow { self.panel.makeKey() }
            }
            return
        }
        preview.show(clip: clip, content: self.previewContent(for: clip), relativeTo: rect, of: collectionView)
        if preview.awaitsImage { loadPreviewImage(for: clip) }
        // 键盘留在卡片区：方向键继续切换条目，浮层只在被点击时才拿走焦点。
        if !panel.isKeyWindow { panel.makeKey() }
    }

    private func closePreview() {
        guard preview.isShown else { return }
        preview.close()
        // 弹出框显示期间面板的第一响应者会被换掉，关掉后放回卡片区。
        panel.makeFirstResponder(collectionView)
        // 浮层拿过键盘焦点的话，它关掉后焦点不会自己回来；而且要等它的窗口真正撤掉之后再取才有效。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.panel.isKeyWindow else { return }
            self.panel.makeKeyAndOrderFront(nil)
        }
    }

    /// 选中项变了或列表刷新后，让已打开的预览跟过去。
    private func updatePreview() {
        guard preview.isShown else { return }
        selectedIndex == nil ? closePreview() : showPreview()
    }

    /// 浮层箭头指向的矩形（集合视图坐标）：卡片本身，不含外侧的选中描边。按原版的浮层位置对出来的。
    private func previewAnchor(forItemAt index: Int) -> NSRect? {
        let outset = PanelMetrics.selectionOutset
        return collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame.insetBy(dx: outset, dy: outset)
    }

    private func previewContent(for clip: ClipSummary) -> PreviewContent {
        switch clip.kind {
        case .text:
            let snapshot = try? store.snapshot(id: clip.id)
            let rich = snapshot?.items.first?.data(for: ClipType.rtf).flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) }
            return .text(snapshot?.plainText ?? clip.previewText, rich: rich)
        case .color:
            let hex = clip.previewText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let display = hex.hasPrefix("#") ? hex : "#" + hex
            guard let color = NSColor(hex: display) else { return .unavailable }
            return .color(color, hex: display)
        case .image:
            // 尺寸用像素数，不用 NSImage.size：带 DPI 信息的截图两者不一样。
            // 知道像素数就先按它把浮层摆好，原图到后台去读，几十 MB 的图也不卡主线程（L09）。
            if let width = clip.pixelWidth, let height = clip.pixelHeight {
                let pixels = NSSize(width: width, height: height)
                return .image(nil, pixelSize: pixels, contentSize: PanelMetrics.previewImageContentSize(pixelSize: pixels, screenSize: previewScreenSize))
            }
            guard let data = (try? store.imageData(id: clip.id)) ?? nil, let image = NSImage(data: data) else { return .unavailable }
            let pixels = image.size
            return .image(image, pixelSize: pixels, contentSize: PanelMetrics.previewImageContentSize(pixelSize: pixels, screenSize: previewScreenSize))
        case .link:
            let text = clip.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: text), url.scheme != nil else { return .unavailable }
            let open = NSWorkspace.shared.defaultApplicationName(for: url).map { String(localized: "在 \($0) 中打开") } ?? String(localized: "打开")
            // 开关关着，或者是本机、内网地址，就不加载网页。
            let notice: String? = if !preferences.generateLinkPreviews {
                String(localized: "链接预览已关闭")
            } else if LinkPolicy.fetchableURL(text) == nil {
                String(localized: "不预览本机和内网地址")
            } else {
                nil
            }
            return .link(url, notice: notice, openTitle: open, size: PanelMetrics.previewLargeSize(screenSize: previewScreenSize))
        case .file:
            let urls = clip.filePaths.map { URL(fileURLWithPath: $0) }
            guard !urls.isEmpty else { return .unavailable }
            return .files(urls, recordedBytes: clip.fileBytes, size: PanelMetrics.previewLargeSize(screenSize: previewScreenSize))
        case .unknown:
            return .unavailable
        }
    }

    /// 超过这么大的文字在后台读（预览、编辑）。
    static let inlineTextLimit = 256 * 1024
    private var textLoadTask: Task<Void, Never>?

    /// 后台读出完整文字和富文本，回到主线程交给 `done`。又发起了新的读取时旧的作废。
    private func loadText(of clip: ClipSummary, _ done: @escaping (String, NSAttributedString?) -> Void) {
        textLoadTask?.cancel()
        let store = store, id = clip.id, fallback = clip.previewText
        textLoadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { () -> (String, Data?) in
                let snapshot = try? store.snapshot(id: id)
                return (snapshot?.plainText ?? fallback, snapshot?.items.first?.data(for: ClipType.rtf))
            }.value
            guard !Task.isCancelled, let self else { return }
            self.textLoadTask = nil
            // 富文本在主线程上解析：NSAttributedString 的 RTF 导入用到 AppKit 的字体和颜色。
            done(loaded.0, loaded.1.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) })
        }
    }

    private func loadPreviewImage(for clip: ClipSummary) {
        previewImageTask?.cancel()
        let store = store
        let id = clip.id
        let size = NSSize(width: clip.pixelWidth ?? 0, height: clip.pixelHeight ?? 0)
        previewImageTask = Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) { Self.decodedImage(store: store, id: id) }.value
            guard !Task.isCancelled, let self else { return }
            self.previewImageTask = nil
            self.preview.setImage(decoded.map { NSImage(cgImage: $0, size: size) }, for: id)
        }
    }

    nonisolated private static let previewMaxPixel = 4_096

    /// 读出原图并立即解码，免得第一次绘制时再在主线程上解码。
    nonisolated private static func decodedImage(store: HistoryStore, id: Int64) -> CGImage? {
        guard let data = (try? store.imageData(id: id)) ?? nil, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // 缩略图接口按 EXIF 方向转正，和 NSImage 的显示一致。最长边限制在 4096：图片视图在主线程上按显示像素重新采样，
        // 4800 万像素的原图出图时要卡 106 ms，限制后约 30 ms，内存也从约 190 MB 降到 50 MB；代价是超大图放大到 2 倍以上会变虚（M5 第 3 步实测）。
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), Self.previewMaxPixel), kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private var previewScreenSize: NSSize {
        (panel.screen ?? NSScreen.main)?.frame.size ?? NSSize(width: 1800, height: 1169)
    }

    @objc private func cardsDidScroll() {
        guard preview.isShown, let index = selectedIndex, let rect = previewAnchor(forItemAt: index) else { return }
        // 卡片滚出屏幕就没有可指的东西了。
        if collectionView.visibleRect.intersects(rect) {
            preview.move(to: rect)
        } else {
            closePreview()
        }
    }

    /// 面板或预览浮层失去键盘焦点后调用：焦点只是在两者之间移动时不收起。
    private func hideIfFocusLeft() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.suppressHideOnResign else { return }
            let key = NSApp.keyWindow
            if key === self.panel || (key != nil && (key === self.preview.window || key === self.filterPanel.popoverWindow)) { return }
            self.hide()
        }
    }

    private static func dotImage(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }

    private func pin(_ clips: [ClipSummary], to board: Pinboard) {
        pin(ids: clips.map(\.id), to: board)
    }

    private func pin(ids: [Int64], to board: Pinboard) {
        do {
            try store.pin(ids: ids, to: board.id)
            reload(selectFirst: false)
        } catch {
            Log.storage.error("固定失败: \(String(describing: error))")
        }
    }

    private func unpin(_ clips: [ClipSummary]) {
        do {
            try store.unpin(ids: clips.map(\.id))
            reload(selectFirst: false)
        } catch {
            Log.storage.error("取消固定失败: \(String(describing: error))")
        }
    }

    /// 在卡片标题位置就地编辑名称。清空名称即恢复显示类型名。
    private func beginRenaming(_ clip: ClipSummary) {
        preview.close()
        guard renameField == nil, let index = visibleClips.firstIndex(where: { $0.id == clip.id }),
              let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { return }
        // 照原版：输入框就在标题的位置，字体颜色一样，原名称全选，直接输入即替换；删空后类型名以浅色占位。
        let typeTitle = ClipCardItem.typeTitle(for: clip)
        let field = NSTextField(string: clip.title ?? typeTitle)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        let card = collectionView.item(at: IndexPath(item: index, section: 0)) as? ClipCardItem
        if let title = card?.beginTitleEditing(in: collectionView) {
            field.font = title.font
            field.textColor = title.color
            field.frame = title.frame.insetBy(dx: -2, dy: 0)
        } else {
            let outset = PanelMetrics.selectionOutset
            field.font = .systemFont(ofSize: 13, weight: .semibold)
            field.frame = NSRect(x: frame.minX + outset + 8, y: frame.minY + outset + 6, width: min(136, frame.width - outset * 2 - 16), height: 22)
        }
        field.placeholderAttributedString = NSAttributedString(string: typeTitle, attributes: [
            .font: field.font ?? .systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: (field.textColor ?? .labelColor).withAlphaComponent(0.45),
        ])
        collectionView.addSubview(field)
        renameField = field
        renamingID = clip.id
        renamingTypeTitle = typeTitle
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        // 光标和文字同色（深色标题栏上是白色），系统默认的蓝色在彩色标题栏上看不清（原版也是同色）。
        (field.currentEditor() as? NSTextView)?.insertionPointColor = field.textColor ?? .labelColor
    }

    private var renamingTypeTitle = ""

    private func endRenaming(commit: Bool) {
        guard let field = renameField, let id = renamingID else { return }
        renameField = nil
        renamingID = nil
        // 和类型名相同就当作没有改名。
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == renamingTypeTitle ? "" : field.stringValue
        field.removeFromSuperview()
        if let index = visibleClips.firstIndex(where: { $0.id == id }) {
            (collectionView.item(at: IndexPath(item: index, section: 0)) as? ClipCardItem)?.endTitleEditing()
        }
        if commit {
            do {
                try store.setTitle(title, for: id)
            } catch {
                Log.storage.error("重命名失败: \(String(describing: error))")
            }
            reload(selectFirst: false)
        }
        panel.makeFirstResponder(collectionView)
    }

    // MARK: Pinboard 管理

    private func menu(for board: Pinboard) -> NSMenu {
        let menu = NSMenu()
        // 和原版一样：重命名、删除…，分隔线下面一行色块（原版还有“共享 Pinboard”，同步不做所以没有）。
        menu.addItem(ClosureMenuItem(String(localized: "重命名")) { [weak self] in self?.toolbar.beginRenaming(board) })
        menu.addItem(ClosureMenuItem(String(localized: "删除…")) { [weak self] in self?.confirmDelete(board) })
        menu.addItem(.separator())
        let swatches = NSMenuItem()
        swatches.view = ColorSwatchRow(colors: Self.pinboardColors, selected: board.colorHex) { [weak self, weak menu] hex in
            menu?.cancelTracking()
            var changed = board
            changed.colorHex = hex
            self?.update(changed)
        }
        menu.addItem(swatches)
        return menu
    }

    private func rename(_ board: Pinboard, to name: String) {
        var changed = board
        changed.name = name
        update(changed)
    }

    private func update(_ board: Pinboard) {
        do {
            try store.updatePinboard(board)
        } catch {
            Log.storage.error("更新 Pinboard 失败: \(String(describing: error))")
        }
        reloadPinboards()
    }

    private func confirmDelete(_ board: Pinboard) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "删除“\(board.name)”？")
        alert.informativeText = String(localized: "只存在于这个 Pinboard 的条目会一并删除，仍在历史中的条目会保留。此操作无法撤销。")
        alert.addButton(withTitle: String(localized: "删除"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.buttons.first?.hasDestructiveAction = true
        WindowSharing.apply(to: alert.window, preferences: preferences)
        // 确认框会抢走 key 窗口，期间不要因为失焦而关掉面板。
        suppressHideOnResign = true
        let response = alert.runModal(defaultButton: 0, cancelButton: 1)
        suppressHideOnResign = false
        panel.makeKeyAndOrderFront(nil)
        guard response == .alertFirstButtonReturn else { return }
        do {
            try store.deletePinboard(id: board.id)
            // 被删内容的撤销记录已经没有意义。
            undoStack.removeAll()
        } catch {
            Log.storage.error("删除 Pinboard 失败: \(String(describing: error))")
        }
        reloadPinboards()
        reload(selectFirst: true)
    }

    private var suppressHideOnResign = false

    // MARK: 列表与 Pinboard

    private func reloadPinboards() {
        pinboards = (try? store.pinboards()) ?? []
        // 当前所在的 Pinboard 被删掉时回到历史。
        if case .pinboard(let id) = scope, !pinboards.contains(where: { $0.id == id }) { scope = .history }
        toolbar.update(pinboards: pinboards, scope: scope)
    }

    private func select(scope newScope: ClipQuery.Scope) {
        guard newScope != scope else { return }
        scope = newScope
        toolbar.update(pinboards: pinboards, scope: scope)
        reload(selectFirst: true)
        if !toolbar.isSearching { panel.makeFirstResponder(collectionView) }
    }

    /// 按工具栏上的顺序在“剪贴板”和各 Pinboard 之间循环切换。
    private func cycleScope(by delta: Int) {
        let scopes: [ClipQuery.Scope] = [.history] + pinboards.map { .pinboard($0.id) }
        guard let index = scopes.firstIndex(of: scope) else { return }
        select(scope: scopes[(index + delta + scopes.count) % scopes.count])
    }

    /// Pinboard 的八种颜色，按原版菜单里色块的顺序（红、橙、黄、绿、蓝、紫、粉、灰），色值从原版取的（M5 第 6 步）。
    static let pinboardColors = ["#FF534C", "#FF9935", "#FAB700", "#29D060", "#009BFF", "#E053F3", "#FF4B66", "#9E9EA3"]
    /// 新建时依次使用的颜色：原版第一个是黄、第二个是蓝，其余顺序没量到。
    private static let newPinboardColors = ["#FAB700", "#009BFF", "#29D060", "#FF534C", "#FF9935", "#E053F3", "#FF4B66", "#9E9EA3"]

    private func createPinboard(named name: String) {
        do {
            let color = Self.newPinboardColors[pinboards.count % Self.newPinboardColors.count]
            let board = try store.createPinboard(name: name, colorHex: color)
            reloadPinboards()
            select(scope: .pinboard(board.id))
        } catch {
            Log.storage.error("创建 Pinboard 失败: \(String(describing: error))")
        }
    }

    // MARK: 更多菜单

    private func showMoreMenu(from anchor: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        addMoreMenuItems(to: menu)
        // 面板高度的两项放在“设置…”前面一组；菜单栏图标的菜单里没有（那时面板不在眼前）。
        if let settings = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
            var index = settings
            for item in panelHeightItems() + [.separator()] {
                menu.insertItem(item, at: index)
                index += 1
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    /// 更多菜单的内容，菜单栏图标的菜单也用这一份。
    /// ⌘T：没暂停就一直暂停到手动恢复（先收起面板），暂停中就恢复（面板留着），和菜单里一样。
    private func togglePause() {
        if pauseStatus().isPaused { onResume?() } else { hide { [weak self] in self?.onPause?(nil) } }
    }

    /// 两处都不放“关于”“帮助”“检查更新”：关于和检查更新在设置的“关于”页，帮助在设置窗口右上角的“?”（用户要求，2026-11-25）。
    func addMoreMenuItems(to menu: NSMenu) {
        menu.addItem(ClosureMenuItem(String(localized: "新文本项")) { [weak self] in self?.newTextItem() })
        let settings = ClosureMenuItem(String(localized: "设置…")) { [weak self] in self?.onSettings?() }
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = .command
        menu.addItem(settings)
        menu.addItem(.separator())

        let status = pauseStatus()
        if status.isPaused {
            let title = status.until.map { String(localized: "已暂停，直到 \($0.formatted(date: .omitted, time: .shortened))") } ?? String(localized: "已暂停")
            let info = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
            // 恢复和定时暂停不收面板，提示叠在面板上方；只有一直暂停会收起面板（原版如此）。
            menu.addItem(ClosureMenuItem(String(localized: "恢复")) { [weak self] in self?.onResume?() }.shortcut("t", .command))
        } else {
            let pause = NSMenuItem(title: String(localized: "暂停 XPaste"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            // ⌘T 和原版一样；面板开着时直接按也能暂停 / 恢复（见 `togglePause`）。
            submenu.addItem(ClosureMenuItem(String(localized: "暂停")) { [weak self] in self?.hide { self?.onPause?(nil) } }.shortcut("t", .command))
            submenu.addItem(.separator())
            for (title, seconds) in [(String(localized: "15 分钟"), 900.0), (String(localized: "30 分钟"), 1_800), (String(localized: "1 小时"), 3_600), (String(localized: "3 小时"), 10_800), (String(localized: "8 小时"), 28_800)] {
                submenu.addItem(ClosureMenuItem(String(localized: "暂停 \(title)")) { [weak self] in self?.onPause?(seconds) })
            }
            pause.submenu = submenu
            menu.addItem(pause)
        }
        menu.addItem(ClosureMenuItem(String(localized: "退出 XPaste")) { NSApp.terminate(nil) })
    }

    private var selectedIndex: Int? {
        visibleClips.firstIndex { $0.id == selectedID }
    }

    /// 选中的条目，按面板上的显示顺序。
    private var selectedClips: [ClipSummary] {
        if let all = allSelectedIDs, all.count > visibleClips.count {
            if let cached = allSelectedClips { return cached }
            let clips = (try? store.summaries(ids: all)) ?? visibleClips.filter { selectedIDs.contains($0.id) }
            allSelectedClips = clips
            return clips
        }
        return visibleClips.filter { selectedIDs.contains($0.id) }
    }

    private func applySelection(scroll: Bool) {
        guard let index = selectedIndex else {
            collectionView.selectionIndexPaths = []
            return
        }
        let path = IndexPath(item: index, section: 0)
        let all = Set(visibleClips.indices.filter { selectedIDs.contains(visibleClips[$0].id) }.map { IndexPath(item: $0, section: 0) })
        // 直接整体替换。先 deselectAll 再选的话，不允许空选中时集合视图会留住原来的一条（描边留在旧卡片上），
        // 而且 deselectAll 会回调代理，把刚算好的选中又改掉。
        collectionView.selectionIndexPaths = all.union([path])
        if scroll, index == 0 {
            // 第一条前面还有提示卡片，回到第一条时滚回最左边，提示也露出来。
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else if scroll {
            collectionView.scrollToItems(at: [path], scrollPosition: .nearestVerticalEdge)
            collectionView.animator().scrollToItems(at: [path], scrollPosition: .nearestVerticalEdge)
        }
    }

    /// ←/→ 移动选中；`extending`（按着 ⇧）时从扩选起点到当前位置之间的全部选中。
    private func moveSelection(by delta: Int, extending: Bool = false) {
        guard !visibleClips.isEmpty else { return }
        let current = selectedIndex ?? 0
        let next = min(max(current + delta, 0), visibleClips.count - 1)
        if extending {
            let anchor = anchorID ?? selectedID
            let anchorIndex = visibleClips.firstIndex { $0.id == anchor } ?? current
            let range = min(anchorIndex, next)...max(anchorIndex, next)
            selectedID = visibleClips[next].id
            selectedIDs = Set(visibleClips[range].map(\.id))
            anchorID = anchor
        } else {
            selectedID = visibleClips[next].id
            anchorID = selectedID
        }
        applySelection(scroll: true)
        announceSelection()
        loadMoreIfNeeded(near: next)
        updatePreview()
    }

    /// ⌘A：选中当前列表（含搜索和筛选）的全部条目，包括还没加载的（L33）。只取 ID，几万条也很快。
    private func selectAll() {
        guard !visibleClips.isEmpty else { return }
        let lead = selectedID ?? visibleClips[0].id
        selectedID = lead
        guard hasMore else {
            let all = visibleClips.map(\.id)
            allSelectedIDs = all
            selectedIDs = Set(all).union([lead])
            applySelection(scroll: false)
            return
        }
        // 还有没加载的：全部 ID 和摘要在后台查（几千上万条时不卡主线程），查回来时列表和选中都没变才生效。
        // 和搜索后马上回车一样，期间的粘贴、删除等按键排在查询后面（`afterQuery`）。
        let store = store, query = currentQuery(), generation = queryGeneration
        queryTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { () -> ([ClipSummary.ID], [ClipSummary])? in
                guard let ids = try? store.clipIDs(matching: query), let clips = try? store.summaries(ids: ids) else { return nil }
                return (ids, clips)
            }.value
            // 列表重查过时 queryTask 已是新的那个，不动它；否则先清掉自己，等着的按键才能继续。
            guard let self, generation == self.queryGeneration else { return }
            self.queryTask = nil
            guard self.selectedID == lead, let (ids, clips) = loaded else { return }
            self.allSelectedIDs = ids
            self.allSelectedClips = clips
            self.selectedIDs = Set(ids).union([lead])
            self.applySelection(scroll: false)
        }
    }

    /// 右键菜单的“创建 Stack”/“添加到 Stack”，右侧标出 Stack 快捷键（Docs/归档/验收记录/Stack改版.md S4）。
    private func stackMenuItem(for clips: [ClipSummary]) -> NSMenuItem {
        let title = isStackOpen() ? String(localized: "添加到 Stack") : String(localized: "创建 Stack")
        let item = ClosureMenuItem(title) { [weak self] in self?.addToStack(clips) }
        if let shortcut = preferences.keyboardSettings.stack {
            let key = RecordedShortcut.keyName(shortcut.keyCode)
            if key.count == 1 { _ = item.shortcut(key.lowercased(), shortcut.flags) }
        }
        return item
    }

    /// Stack 快捷键在面板开着时按下：用选中项创建或追加 Stack，面板收起。没有选中项时返回 false。
    func addSelectionToStack() -> Bool {
        let clips = selectedClips
        guard !clips.isEmpty else { return false }
        addToStack(clips)
        return true
    }

    private func addToStack(_ clips: [ClipSummary]) {
        hide { [weak self] in self?.onAddToStack?(clips) }
    }

    private func pasteSelection(plainText: Bool, direct: Bool = true) {
        paste(selectedClips, plainText: plainText, direct: direct)
    }

    private func paste(_ clips: [ClipSummary], plainText: Bool, direct: Bool = true) {
        guard !clips.isEmpty else { return }
        let target = targetApp
        // 面板移出屏幕后键盘焦点才回到目标应用，所以等收起动画结束再回放。
        hide { [weak self] in
            guard let self else { return }
            self.onPaste?(clips, plainText || self.preferences.alwaysPastePlainText, direct && self.preferences.pasteToApplication, target)
        }
    }

    func privacyDidChange() {
        // 关掉预览开关时立即释放已打开的网页，保留既有卡片元数据。
        if !preferences.generateLinkPreviews { closePreview() }
    }

    func historyWasErased() {
        closePreview()
        undoStack.removeAll()
        historyDidChange()
    }

    // MARK: 键盘

    private func handleNavigationKey(_ event: NSEvent) -> Bool {
        // 文本框里 ⌘←／⌘→ 是移动光标；只有空的搜索框里也能切换 Pinboard。
        if let editor = panel.firstResponder as? NSTextView {
            guard editor === searchField.currentEditor(), !editor.hasMarkedText(), editor.string.isEmpty else { return false }
        }
        let settings = preferences.keyboardSettings
        if settings.nextPinboard?.matches(event) == true { cycleScope(by: 1); return true }
        if settings.previousPinboard?.matches(event) == true { cycleScope(by: -1); return true }
        return false
    }

    /// 卡片区获得焦点时的按键。返回 true 表示已处理。
    private func handleKey(_ event: NSEvent) -> Bool {
        if (panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
        // 查询还没回来时，除了 Esc 和直接打字，其余按键都作用于列表，等新结果到了再处理同一个按键。
        if queryTask != nil, event.keyCode != 53, !Self.isTyping(event) {
            afterQuery { [weak self] in _ = self?.handleKey(event) }
            return true
        }
        if handleNavigationKey(event) { return true }
        let keyboard = preferences.keyboardSettings
        let plainModifier = keyboard.plainText.flags
        // 方向键自带 numericPad 和 function 标志，比较修饰键前先去掉。
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }) ?? Self.digit(forKeyCode: event.keyCode),
           (1...9).contains(digit), flags == keyboard.quickPaste.flags || flags == keyboard.quickPaste.flags.union(plainModifier) {
            if digit <= visibleClips.count { paste([visibleClips[digit - 1]], plainText: flags.contains(plainModifier)) }
            return true
        }
        switch Int(event.keyCode) {
        case 45 where flags == [.command, .shift]: toolbar.beginCreatingPinboard(); return true // ⇧⌘N
        case 8 where flags == .command: // ⌘C 复制到剪贴板，不粘贴
            pasteSelection(plainText: false, direct: false)
            return true
        case 0 where flags == .command: selectAll(); return true // ⌘A
        case 17 where flags == .command: togglePause(); return true // ⌘T 暂停 / 恢复
        case 6 where flags == .command: undoDelete(); return true // ⌘Z
        case 14 where flags == .command: editSelection(); return true // ⌘E
        case 45 where flags == .command: newTextItem(); return true // ⌘N
        case 15 where flags == .command: // ⌘R 重命名
            if let index = selectedIndex { beginRenaming(visibleClips[index]) }
            return true
        case 123 where flags.isEmpty || flags == .shift: moveSelection(by: -1, extending: flags == .shift); return true // ←，按着 ⇧ 扩选
        case 124 where flags.isEmpty || flags == .shift: moveSelection(by: 1, extending: flags == .shift); return true // →
        case 36, 76:
            guard flags.isEmpty || flags == plainModifier else { return false }
            pasteSelection(plainText: flags.contains(plainModifier)); return true // Return / Enter
        case 49 where flags.isEmpty: togglePreview(); return true // Space
        case 53: // Esc 先关预览，再关面板
            if preview.isShown { closePreview() } else { hide() }
            return true
        case 51, 117: // Delete / Forward Delete
            closePreview()
            deleteSelection()
            return true
        default: break
        }

        // 直接打字即开始搜索：把焦点交给搜索框后重新派发这次按键，输入法也能正常接到。
        if flags.isDisjoint(with: [.command, .control]), let chars = event.characters, !chars.isEmpty,
           chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }) {
            focusSearch()
            panel.sendEvent(event)
            return true
        }
        return false
    }

    // MARK: 辅助功能

    /// VoiceOver 对一张卡片的操作走和键盘、右键菜单相同的路径。按 ID 找条目，卡片被复用后也不会作用到别的条目上。
    private func configureAccessibility(_ card: ClipCardItem, for id: ClipSummary.ID) {
        card.onAccessibilityPress = { [weak self] in
            guard let self, let clip = self.visibleClips.first(where: { $0.id == id }) else { return }
            self.paste([clip], plainText: false)
        }
        card.accessibilityMenu = { [weak self] in
            guard let self, let index = self.visibleClips.firstIndex(where: { $0.id == id }) else { return nil }
            return self.contextMenu(forItemAt: IndexPath(item: index, section: 0))
        }
        card.accessibilityActions = { [weak self] in
            guard let self, let clip = self.visibleClips.first(where: { $0.id == id }) else { return [] }
            func action(_ name: String, _ perform: @escaping (PanelController, ClipSummary) -> Void) -> NSAccessibilityCustomAction {
                NSAccessibilityCustomAction(name: name) { [weak self] in
                    guard let self, let clip = self.visibleClips.first(where: { $0.id == id }) else { return false }
                    perform(self, clip)
                    return true
                }
            }
            var actions = [
                action(String(localized: "以纯文本粘贴")) { $0.paste([$1], plainText: true) },
                action(String(localized: "复制")) { $0.paste([$1], plainText: false, direct: false) },
                action(String(localized: "预览")) { $0.selectOnly($1.id); $0.showPreview() },
            ]
            if [.text, .link, .color, .image].contains(clip.kind) { actions.append(action(String(localized: "编辑")) { $0.edit($1) }) }
            actions.append(action(String(localized: "删除")) { $0.selectOnly($1.id); $0.closePreview(); $0.deleteSelection() })
            return actions
        }
    }

    private func selectOnly(_ id: ClipSummary.ID) {
        selectedID = id
        anchorID = id
        applySelection(scroll: true)
    }

    /// 选中变了以后告诉辅助功能：卡片区的焦点元素是当前选中的那张卡片，VoiceOver 会移过去读出来。
    private func announceSelection() {
        guard panel.firstResponder === collectionView else { return }
        NSAccessibility.post(element: collectionView, notification: .focusedUIElementChanged)
    }

    /// 不带 ⌘、⌃ 的可见字符：会转去搜索框，不依赖列表。
    private static func isTyping(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control]), let chars = event.characters, !chars.isEmpty else { return false }
        return chars.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) && $0 != " " }
    }

    private static func digit(forKeyCode keyCode: UInt16) -> Int? {
        [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9][keyCode]
    }

    private func focusSearch() {
        closePreview()
        toolbar.isSearching = true
        panel.makeFirstResponder(searchField)
        // 成为第一响应者时默认会全选，改为把光标放到末尾。
        searchField.currentEditor()?.selectedRange = NSRange(location: searchField.stringValue.utf16.count, length: 0)
    }
}

extension PanelController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        // 只有拖动排序时的落点竖线；提示卡片不走分区头，见 `tips`。
        collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: DropIndicatorView.identifier, for: indexPath)
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        visibleClips.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ClipCardItem.identifier, for: indexPath)
        if let card = item as? ClipCardItem {
            let clip = visibleClips[indexPath.item]
            let pinboardColor = clip.listID.flatMap { id in pinboards.first { $0.id == id } }.flatMap { NSColor(hex: $0.colorHex) }
            var inPinboard = false
            if case .pinboard = scope { inPinboard = true }
            card.configure(with: clip, now: Date(), compact: isCompact, pinboardColor: pinboardColor, inPinboard: inPinboard)
            configureAccessibility(card, for: clip.id)
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        // 插入操作不能在布局回调里同步进行。延后期间列表可能已被重载或清空，版本变了就放弃。
        let generation = dataGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.dataGeneration == generation else { return }
            self.loadMoreIfNeeded(near: indexPath.item)
        }
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let index = indexPaths.first?.item, visibleClips.indices.contains(index) else { return }
        syncSelection(lead: visibleClips[index].id)
        panel.makeFirstResponder(collectionView)
        updatePreview()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        // ⌘ 点掉多选里的一条。
        syncSelection(lead: nil)
        updatePreview()
    }

    /// 鼠标点选之后把集合视图里的选中状态同步过来。`lead` 是刚点的那一条。
    private func syncSelection(lead: ClipSummary.ID?) {
        let chosen = collectionView.selectionIndexPaths.map(\.item).filter(visibleClips.indices.contains).sorted().map { visibleClips[$0].id }
        guard let leadID = lead ?? (selectedID.flatMap { chosen.contains($0) ? $0 : nil }) ?? chosen.first else { return }
        selectedID = leadID
        selectedIDs = Set(chosen).union([leadID])
        if chosen.count <= 1 { anchorID = leadID }
    }
}

// MARK: 卡片手势

/// 按在卡片上的一次按下。用条目 ID 记，按住期间列表变了也认得是哪一条。
struct CardPress {
    let clipID: ClipSummary.ID
    let downEvent: NSEvent
    /// 按在已选中的多选组里（没按修饰键）：先保留整组以便拖整组，确认只是单击后再收拢成这一条。
    let collapsesOnClick: Bool
}

extension PanelController {
    /// 光标离开按下位置超过这个距离（点）就起拖，否则算点击（原版 Paste 6.6.2 是 3 点）。
    static let dragThreshold: CGFloat = 3

    fileprivate func cardMouseDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌃ 点按是右键菜单，交给集合视图。
        guard !flags.contains(.control) else { return false }
        // 先拿焦点：正在重命名的话这一下会提交，列表可能随之变化，所以之后再找按到的卡片。
        panel.makeFirstResponder(collectionView)
        guard let path = collectionView.indexPathForItem(at: collectionView.convert(event.locationInWindow, from: nil)),
              visibleClips.indices.contains(path.item) else {
            cardPress = nil
            return false
        }
        let id = visibleClips[path.item].id
        if event.clickCount < 2 || lastClickedID != id { lastClickedID = nil }
        var collapses = false
        if flags.contains(.command) {
            toggleSelection(id)
        } else if flags.contains(.shift) {
            extendSelection(to: path.item)
        } else if selectedIDs.contains(id), selectedIDs.count > 1 {
            collapses = true
        } else if selectedID != id || selectedIDs.count > 1 {
            // 按到未选中的卡片立即选中；同一次按住超过阈值就直接起拖。
            changeSelection(lead: id, ids: [id])
        }
        cardPress = CardPress(clipID: id, downEvent: event, collapsesOnClick: collapses)
        return true
    }

    fileprivate func cardMouseDragged(_ event: NSEvent) -> Bool {
        guard let press = cardPress else { return false }
        let start = press.downEvent.locationInWindow, now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > Self.dragThreshold else { return true }
        // 起拖之后集合视图收不到这次的松手，按下的记录在这里就结束。
        cardPress = nil
        lastClickedID = nil
        beginCardDrag(press, with: event)
        if activeDrag == nil { cardGestureDidEnd() }
        return true
    }

    fileprivate func cardMouseUp(_ event: NSEvent) -> Bool {
        guard let press = cardPress else { return false }
        cardPress = nil
        defer { cardGestureDidEnd() }
        if press.collapsesOnClick { changeSelection(lead: press.clipID, ids: [press.clipID]) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let releasedID = collectionView.indexPathForItem(at: collectionView.convert(event.locationInWindow, from: nil))
            .flatMap { visibleClips.indices.contains($0.item) ? visibleClips[$0.item].id : nil }
        guard releasedID == press.clipID, flags.isDisjoint(with: [.command, .shift]) else {
            lastClickedID = nil
            return true
        }
        // 第二次松手时仍是同一条、中间没有起拖，才算双击（间隔用系统的双击间隔，由 clickCount 体现）。
        if event.clickCount >= 2, lastClickedID == press.clipID, let index = visibleClips.firstIndex(where: { $0.id == press.clipID }) {
            lastClickedID = nil
            collectionView.doubleClickHandler?(IndexPath(item: index, section: 0))
        } else {
            lastClickedID = press.clipID
        }
        return true
    }

    /// 按住或拖动结束：补做期间被延后的后台刷新。
    fileprivate func cardGestureDidEnd() {
        guard !cardGestureActive, pendingBackgroundReload else { return }
        pendingBackgroundReload = false
        reload(selectFirst: false, background: true)
    }

    /// ⌘ 点按：加入或移出多选。至少留一条。
    private func toggleSelection(_ id: ClipSummary.ID) {
        let current = visibleClips.map(\.id).filter(selectedIDs.contains)
        if selectedIDs.contains(id) {
            let rest = current.filter { $0 != id }
            guard let lead = selectedID != id ? selectedID : rest.first, !rest.isEmpty else { return }
            changeSelection(lead: lead, ids: Set(rest), anchor: anchorID == id ? lead : anchorID)
        } else {
            changeSelection(lead: id, ids: Set(current).union([id]))
        }
    }

    /// ⇧ 点按：从扩选起点到按下的卡片之间全部选中。
    private func extendSelection(to index: Int) {
        let anchor = anchorID ?? selectedID
        let anchorIndex = visibleClips.firstIndex { $0.id == anchor } ?? index
        let range = min(anchorIndex, index)...max(anchorIndex, index)
        changeSelection(lead: visibleClips[index].id, ids: Set(visibleClips[range].map(\.id)), anchor: anchor)
    }

    /// 鼠标改选中：和原来集合视图点选后同步过来的结果一致（⌘A 的整表选中随之清掉）。
    /// `anchor` 不给时，只选一条就把扩选起点设成它。
    private func changeSelection(lead: ClipSummary.ID, ids: Set<ClipSummary.ID>, anchor: ClipSummary.ID?? = nil) {
        selectedID = lead
        selectedIDs = ids.union([lead])
        if let anchor { anchorID = anchor } else if selectedIDs.count == 1 { anchorID = lead }
        applySelection(scroll: false)
        updatePreview()
    }
}

/// 拖动中按了 Esc 之后马上结束拖动会话。
/// 系统不一定把 Esc 交给拖动会话（面板在前台时就不会，L110），于是发一个松开鼠标的事件让会话立刻结束。
/// 调用前允许的操作和拖动带的内容都已清空，松手处谁也接不住，结果就是取消，在那里冒云团（和 Stack 一样，用户真机要求）。
/// 发事件要辅助功能授权；没有授权时只能等用户自己松手。
@MainActor
enum DragCancellation {
    static func endDragNow() {
        guard PastePerformer.isTrusted, let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let location = CGEvent(source: nil)?.location ?? .zero
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}

/// 卡片拖动的拖拽来源。每次会话一个实例，会话的状态（定时器、拖动图是否缩小、是否已按 Esc）都放在这里，会话结束就丢掉。
@MainActor
final class CardDragSource: NSObject, NSDraggingSource {
    var session: NSDraggingSession?
    /// false 是拖动中按了 Esc：什么操作都不允许，目标不会接收。
    var allowsOperations = true
    private(set) var imageShrunk = false
    var onBegin: ((NSDraggingSession) -> Void)?
    var onEnd: ((NSDraggingSession, NSPoint, NSDragOperation) -> Void)?
    private var timer: Timer?

    /// 拖到别的应用是复制；面板内部（Pinboard 里排序、放到页签上）可以移动。
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        guard allowsOperations else { return [] }
        return context == .withinApplication ? [.move, .copy] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        self.session = session
        onBegin?(session)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onEnd?(session, screenPoint, operation)
        onBegin = nil
        onEnd = nil
        self.session = nil
    }

    /// 拖动期间每 0.05 秒检查一次，跑到会话结束。
    func startWatching(_ tick: @escaping @MainActor () -> Void) {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    /// 以鼠标为中心缩放拖动图。拖放会话里的位置是屏幕坐标。
    func resizeImage(shrink: Bool) {
        guard let session else { return }
        imageShrunk = shrink
        let factor = shrink ? PanelMetrics.dragImageScale : 1 / PanelMetrics.dragImageScale
        let cursor = NSEvent.mouseLocation
        session.enumerateDraggingItems(options: [], for: nil, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
            let frame = item.draggingFrame
            let scaled = NSRect(x: cursor.x + (frame.minX - cursor.x) * factor, y: cursor.y + (frame.minY - cursor.y) * factor,
                                width: frame.width * factor, height: frame.height * factor)
            item.setDraggingFrame(scaled, contents: item.imageComponents?.first?.contents)
        }
    }
}

// MARK: 拖拽

extension PanelController {
    /// 集合视图自己不起拖：拖动一律由卡片手势处理启动（见 `beginCardDrag`）。
    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { false }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        guard visibleClips.indices.contains(indexPath.item) else { return nil }
        let clip = visibleClips[indexPath.item]
        return ClipDragProvider.pasteboardItem(store: store, content: .single(clip), idsField: String(clip.id))
    }

    /// 按下第 `pressed` 张时拖走的条目：它在多选里就是整组（含 ⌘A 选中但还没加载的），否则只有它自己。
    private func draggedClips(pressed: Int) -> [ClipSummary] {
        let clip = visibleClips[pressed]
        return selectedIDs.contains(clip.id) ? selectedClips : [clip]
    }

    /// 每个拖动项的内容。多选里有文本时，和粘贴一样只交出合并后的文本：放在第一个拖动项上，其余只带条目 ID（L35）。
    private func dragWriters(for clips: [ClipSummary]) -> [NSPasteboardItem] {
        let composesText = clips.count > 1 && clips.contains { [.text, .link, .color].contains($0.kind) }
        return clips.enumerated().map { offset, clip in
            guard composesText else {
                return ClipDragProvider.pasteboardItem(store: store, content: .single(clip), idsField: String(clip.id))
            }
            if offset == 0 {
                return ClipDragProvider.pasteboardItem(store: store, content: .composed(clips.map(\.id)), idsField: String(clip.id))
            }
            let writer = NSPasteboardItem()
            writer.setString(String(clip.id), forType: ClipDrag.idsType)
            return writer
        }
    }

    /// 用卡片快照和独立的拖拽来源启动系统拖拽会话。原卡片留在原处不动（原版如此，L36），拖动图单独跟着鼠标。
    /// 拖的是按下的那一条；它在多选里时拖整组（显示顺序）。
    ///
    /// 起拖时冻结一份有序的条目 ID（审查 08）：⌘A 选中了还没加载的条目时，拖出的内容、拖动项和内部用的 ID 都是这同一份完整范围。
    /// 内容只声明类型，接收方要时才读（`ClipDragProvider`，审查 05）。
    private func beginCardDrag(_ press: CardPress, with event: NSEvent) {
        let signpost = Log.signposter.beginInterval("drag.begin", id: Log.signposter.makeSignpostID())
        defer { Log.signposter.endInterval("drag.begin", signpost) }
        guard renameField == nil, let pressed = visibleClips.firstIndex(where: { $0.id == press.clipID }) else { return }
        let clips = draggedClips(pressed: pressed)
        guard !clips.isEmpty else { return }
        let loaded = Dictionary(visibleClips.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pressedFrame = collectionView.layoutAttributesForItem(at: IndexPath(item: pressed, section: 0))?.frame ?? .zero
        var items: [NSDraggingItem] = []
        for (clip, writer) in zip(clips, dragWriters(for: clips)) {
            let item = NSDraggingItem(pasteboardWriter: writer)
            let path = loaded[clip.id].map { IndexPath(item: $0, section: 0) }
            if let path, let card = collectionView.item(at: path) {
                // 快照现在就取好：拖动开始后卡片可能被复用或重画。
                let components = card.draggingImageComponents
                item.draggingFrame = collectionView.convert(card.view.bounds, from: card.view)
                item.imageComponentsProvider = { components }
            } else {
                // 不在屏幕上（或还没加载）的条目只带内容，不带图。
                item.draggingFrame = path.flatMap { collectionView.layoutAttributesForItem(at: $0)?.frame } ?? pressedFrame
            }
            items.append(item)
        }
        guard !items.isEmpty else { return }
        let source = CardDragSource()
        source.onBegin = { [weak self, weak source] session in
            guard let self, let source, self.activeDrag === source else { return }
            self.preview.close()
            self.watchDragLeavingPanel(source)
        }
        let cardSide = pressedFrame.width
        source.onEnd = { [weak self, weak source] session, point, operation in
            guard let self, let source else { return }
            source.stopWatching()
            // 取消或没放下（包括拖动中按 Esc）：在松手处冒一团云，代替飞回原位的动画。
            // 系统的效果自己播完，不拦着下一次拖动；连着取消几次就有几团同时在播。
            if operation.isEmpty || !source.allowsOperations {
                Self.poof(at: point, cardSide: source.imageShrunk ? cardSide * PanelMetrics.dragImageScale : cardSide)
            }
            // 放到别的应用里算用过一次，和粘贴一样回到历史最前。
            let ids = ClipDrag.ids(from: session.draggingPasteboard)
            if operation == .copy, !self.isVisible, !ids.isEmpty {
                try? self.store.touch(ids: ids)
            }
            // 旧会话迟到的结束回调不清下一次的状态。
            guard self.activeDrag === source else { return }
            self.activeDrag = nil
            self.cardGestureDidEnd()
        }
        activeDrag = source
        let session = collectionView.beginDraggingSession(with: items, event: press.downEvent, source: source)
        // 取消或没放下时不播放飞回原位的动画，拖动图直接消失，马上可以再拖下一次。
        session.animatesToStartingPositionsOnCancelOrFail = false
        session.draggingFormation = .none
        source.session = session
    }

    /// 拖拽取消时的云团（参考 Orivo 的关闭效果，用系统的 `NSAnimationEffect.poof`）。大小随拖动图，限制在 48–120 点；
    /// 开启“减弱动态效果”时不播。
    static func poof(at point: NSPoint, cardSide: CGFloat) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let side = min(max(cardSide * 0.6, 48), 120)
        NSAnimationEffect.poof.show(centeredAt: point, size: NSSize(width: side, height: side))
    }

    /// 拖出面板范围就把面板收起，让出下面的应用（原版实测）。
    private func watchDragLeavingPanel(_ drag: CardDragSource) {
        var leftPanel = false
        drag.startWatching { [weak self, weak drag] in
            guard let self, let drag else { return }
            // 拖动中按 Esc 取消（L110）：拖动循环里按键事件不一定送到面板，直接看键盘状态。
            if drag.allowsOperations, CGEventSource.keyState(.combinedSessionState, key: 53) {
                drag.allowsOperations = false
                // 别的应用只在拖动开始时问一次允许什么操作，中途改不管用；把拖动带的内容清空，它们松手时读不到东西。
                drag.session?.draggingPasteboard.clearContents()
                // 不等用户松手，马上结束拖动、冒云团。
                DragCancellation.endDragNow()
            }
            // 面板收起后拖动还在继续，定时器要跑到拖动结束，Esc 才一直有效。
            guard !leftPanel, self.isVisible, self.activeDrag === drag else { return }
            // 在卡片区里拖动图是原尺寸，到卡片区上方（工具栏一带）缩小（原版实测，L37）。
            let cardsTop = self.scrollView.window.map { self.scrollView.convert(self.scrollView.bounds, to: nil).maxY + $0.frame.minY } ?? .greatestFiniteMagnitude
            let aboveCards = NSEvent.mouseLocation.y > cardsTop
            if aboveCards != drag.imageShrunk { drag.resizeImage(shrink: aboveCards) }
            guard NSEvent.mouseLocation.y > self.panel.frame.maxY else { return }
            leftPanel = true
            self.hide()
        }
    }

    /// 是面板当前这次拖拽、没被 Esc 取消、带着条目 ID。页签投放和排序都先过这一关。
    private func isOwnActiveDrag(_ info: any NSDraggingInfo) -> Bool {
        guard let source = info.draggingSource as? CardDragSource, source === activeDrag, source.allowsOperations else { return false }
        return !ClipDrag.ids(from: info.draggingPasteboard).isEmpty
    }

    /// Pinboard 里拖动排序：只在不搜索、不筛选时可以。
    private func canReorder(_ info: any NSDraggingInfo) -> Bool {
        guard case .pinboard = scope, isOwnActiveDrag(info) else { return false }
        return searchField.stringValue.isEmpty && filter.isEmpty
    }

    // 面板内部的落点只有一种：在 Pinboard 里拖动排序。
    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo, proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard canReorder(draggingInfo) else { return [] }
        // 系统给的“落在某张卡片上”一律改成插在旁边：光标在卡片右半边就放到它后面。
        if proposedDropOperation.pointee == .on {
            let item = proposedDropIndexPath.pointee.item
            let point = collectionView.convert(draggingInfo.draggingLocation, from: nil)
            if let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame, point.x > frame.midX {
                proposedDropIndexPath.pointee = NSIndexPath(forItem: item + 1, inSection: 0)
            }
        }
        proposedDropOperation.pointee = .before
        return .move
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: any NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        // 松手时用和拖动过程中同一个判断（审查 08）。
        guard case .pinboard(let listID) = scope, canReorder(draggingInfo) else { return false }
        let ids = ClipDrag.ids(from: draggingInfo.draggingPasteboard)
        let target = visibleClips.indices.contains(indexPath.item) ? visibleClips[indexPath.item].id : nil
        do {
            try store.movePinned(ids: ids, in: listID, before: target)
        } catch {
            Log.storage.error("排序失败: \(String(describing: error))")
            return false
        }
        reload(selectFirst: false)
        return true
    }
}

extension PanelController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === searchField else { return }
        searchBar.isLastTokenSelected = false
        reload(selectFirst: true)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // 重命名时点到别处，按提交处理。
        if notification.object as AnyObject? === renameField { endRenaming(commit: true) }
    }

    // 输入法组字期间这些命令不会走到这里，选词的 Return 不会被当成粘贴。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === renameField {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): endRenaming(commit: true); return true
            case #selector(NSResponder.cancelOperation(_:)): endRenaming(commit: false); return true
            default: return false
            }
        }
        // 选中的标记只等下一次退格；别的按键都取消选中。
        let tokenWasSelected = searchBar.isLastTokenSelected
        searchBar.isLastTokenSelected = false
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            // Return 先进入结果导航，再按一次才粘贴。
            panel.makeFirstResponder(collectionView)
            applySelection(scroll: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Esc 逐级回退：收起筛选浮层 → 清空搜索词和筛选 → 收起搜索框；面板本身由卡片区的 Esc 关闭。
            if filterPanel.isVisible {
                filterPanel.close()
            } else if !searchField.stringValue.isEmpty || !filter.isEmpty {
                clearSearch()
            } else {
                toolbar.isSearching = false
                panel.makeFirstResponder(collectionView)
            }
            return true
        case #selector(NSResponder.deleteBackward(_:)) where searchField.stringValue.isEmpty && !filter.isEmpty:
            // 输入框已空时退格：第一次选中最后一个筛选标记，再按一次才删掉（原版如此）。
            if tokenWasSelected { filterPanel.removeLastToken() } else { searchBar.isLastTokenSelected = true }
            return true
        default:
            return false
        }
    }
}

extension PanelController: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        guard !suppressHideOnResign else { return }
        // 预览或筛选浮层开着时焦点可能只是进了浮层（点了里面的文字、弹出框刚出现）。
        if preview.isShown || filterPanel.isVisible { hideIfFocusLeft() } else { hide() }
    }
}

extension PanelController: @preconcurrency NSSharingServicePickerDelegate {
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        suppressHideOnResign = false
        // 选了服务就让位给它的窗口；取消则把键盘还给面板。
        if service != nil { hide() } else if isVisible { panel.makeKeyAndOrderFront(nil) }
    }
}

extension NSMenuItem {
    /// macOS 27 起菜单默认隐藏图标（用 27 SDK 编译的应用才受影响，原版是 26.5 SDK），要显示的图标得单独声明（L117）。
    func setVisibleImage(_ image: NSImage?) {
        self.image = image
        preferredImageVisibility = .visible
    }
}

/// 用闭包做动作的菜单项。
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func run() { handler() }

    /// 在菜单项右侧标出对应的按键，和原版一样（菜单只在打开时响应这些键，与面板自己的按键处理不冲突）。
    func shortcut(_ key: String, _ modifiers: NSEvent.ModifierFlags = []) -> Self {
        keyEquivalent = key
        keyEquivalentModifierMask = modifiers
        return self
    }
}

#if DEBUG || BENCH
/// 自检和测量用的观察口，只在调试和测量构建里存在。
extension PanelController {
    var debugPanelHeight: CGFloat { panelHeight }
    var debugPreferences: AppPreferences { preferences }
    var debugWindowHeight: CGFloat { panel.frame.height }
    func debugDragHeight(by delta: CGFloat, ended: Bool) { resizePanel(by: delta, ended: ended) }
    var debugHeightTip: (text: String, visible: Bool) { (heightLabel.stringValue, !heightLabel.isHidden) }
    func debugBeginHeightDrag() { beginHeightDrag() }
    var debugPanelIgnoresMouseEvents: Bool { panel.ignoresMouseEvents }
    /// 窗口外框，以及玻璃上缘在屏幕上的纵坐标。
    var debugHeightDragGeometry: (window: NSRect, glassTop: CGFloat, handleCoversExtension: Bool) {
        let glassTop = panel.frame.minY + panelHeight
        let handle = resizeHandle.convert(resizeHandle.bounds, to: nil)
        return (panel.frame, glassTop, handle.maxY >= panel.frame.height - 0.5 && handle.minY <= panelHeight - PanelMetrics.resizeHandleHeight + 0.5)
    }
    var debugLockBadgeVisible: Bool { !lockBadge.isHidden }
    var debugEdgeGlowLit: Bool { edgeGlow.isLit }
    func debugHoverEdge(_ value: Bool) { resizeHandle.debugHover(value) }
    var debugResizeDirections: NSCursor.FrameResizeDirection.Set { resizeHandle.directions }
    func debugClickLockBadge() { lockBadge.performClick(nil) }
    var debugMoreMenuTitles: [String] {
        let menu = NSMenu()
        addMoreMenuItems(to: menu)
        return menu.items.map(\.title)
    }
    func debugDoubleClickHeightHandle() { resizeHandle.onDoubleClick?() }
    var debugHeightAnimating: Bool { heightAnimation != nil }
    /// 上缘右键菜单：标题、能不能点、有没有勾。
    var debugHeightMenu: [(title: String, enabled: Bool, on: Bool)] { panelHeightMenu().items.map { ($0.title, $0.isEnabled, $0.state == .on) } }
    var debugSelectedID: ClipSummary.ID? { selectedID }
    var debugSelectedIndex: Int? { selectedIndex }
    var debugSelectedCount: Int { selectedIDs.count }
    var debugSelectedClipCount: Int { selectedClips.count }
    /// 集合视图自己记的选中位置，用来核对和 `selectedIDs` 一致（卡片的描边和辅助功能的“已选中”都看它）。
    var debugCollectionSelection: [Int] { collectionView.selectionIndexPaths.map(\.item).sorted() }
    var debugFilterPanel: FilterPanel { filterPanel }
    var debugFilter: FilterState { filter }
    func debugToggleFilter() {
        focusSearch()
        toggleFilterPanel()
    }
    /// 搜索框里按一次退格（走输入框的命令路径）。
    func debugSearchBackspace() {
        focusSearch()
        guard let editor = searchField.currentEditor() as? NSTextView else { return }
        _ = control(searchField, textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
    }
    var debugLastTokenSelected: Bool { searchBar.isLastTokenSelected }
    var debugWindow: NSWindow { panel }
    var debugSearchBarFrame: NSRect { panel.convertToScreen(searchBar.convert(searchBar.bounds, to: nil)) }
    var debugSearchFocused: Bool { panel.firstResponder === searchField.currentEditor() }
    func debugDoubleClick(index: Int) { collectionView.doubleClickHandler?(IndexPath(item: index, section: 0)) }
    /// 在一张卡片中心（可加偏移）合成按下、拖动或松手事件，走真实的鼠标手势路径。拖动超过阈值会真的起拖，自检里不用。
    func debugMouse(_ type: NSEvent.EventType, index: Int, clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = [], offset: CGFloat = 0) {
        guard let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { return }
        let point = collectionView.convert(NSPoint(x: frame.midX + offset, y: frame.midY), to: nil)
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1) else { return }
        switch type {
        case .leftMouseDown: collectionView.mouseDown(with: event)
        case .leftMouseDragged: collectionView.mouseDragged(with: event)
        default: collectionView.mouseUp(with: event)
        }
    }
    var debugCardPressed: Bool { cardPress != nil }
    var debugPendingBackgroundReload: Bool { pendingBackgroundReload }
    var debugDisplayedTips: [PanelTip] { displayedTips ?? [] }
    /// 提示卡片之间、最后一张提示和第一张历史卡片之间的间距（与卡片间距相同）。
    var debugTipSpacing: CGFloat { tips.spacing }
    /// 和点提示卡片上的 × 一样。
    func debugCloseTip(_ tip: PanelTip) {
        guard let index = displayedTips?.firstIndex(of: tip), tips.arrangedSubviews.indices.contains(index) else { return }
        (tips.arrangedSubviews[index] as? PanelTipView)?.onDismiss?()
    }
    /// 集合视图里装提示的容器个数（应始终是 1），以及第一张历史卡片中心点命中的是不是这张卡片自己（L141）。
    var debugTipContainerCount: Int { collectionView.subviews.filter { $0 is NSStackView }.count }
    var debugFirstCardHitIsCard: Bool {
        guard let item = collectionView.item(at: IndexPath(item: 0, section: 0)), let superview = collectionView.superview else { return false }
        let center = collectionView.convert(NSPoint(x: item.view.frame.midX, y: item.view.frame.midY), to: superview)
        return collectionView.hitTest(center)?.isDescendant(of: item.view) == true
    }
    /// 提示卡片和第一张卡片在窗口里的位置；横向滚动后两者应一起移动。
    var debugTipAndFirstCardFrames: (tips: [NSRect], card: NSRect?) {
        (tips.arrangedSubviews.map { $0.convert($0.bounds, to: nil) },
         collectionView.item(at: IndexPath(item: 0, section: 0)).map { $0.view.convert($0.view.bounds, to: nil) })
    }
    /// 一张卡片在辅助功能里的样子：名称、是否选中、子元素个数、自定义操作，以及卡片区的焦点是不是它。
    func debugCardAccessibility(index: Int) -> (label: String, selected: Bool, children: Int, actions: [String], focused: Bool)? {
        guard let item = collectionView.item(at: IndexPath(item: index, section: 0)) as? ClipCardItem else { return nil }
        return (item.accessibilityLabel() ?? "", item.isAccessibilitySelected(), item.accessibilityChildren()?.count ?? -1,
                item.accessibilityCustomActions()?.map(\.name) ?? [], collectionView.accessibilityFocusedUIElement as? ClipCardItem === item)
    }
    var debugSelectedPreviews: [String] { selectedClips.map(\.previewText) }
    var debugUndoDepth: Int { undoStack.count }
    var debugHasRefreshTimer: Bool { timeRefreshTimer != nil }
    var debugLoadedCount: Int { visibleClips.count }

    func debugSelect(index: Int) {
        guard visibleClips.indices.contains(index) else { return }
        selectedID = visibleClips[index].id
        applySelection(scroll: false)
    }
    /// 和 ⇧ 扩选一样：选中一段，`index` 是当前选中的那张。
    func debugSelect(indexes: ClosedRange<Int>, current index: Int) {
        guard visibleClips.indices.contains(indexes.lowerBound), visibleClips.indices.contains(indexes.upperBound) else { return }
        // 先设当前项（它会把多选重置成这一张），再设整段。
        selectedID = visibleClips[index].id
        anchorID = visibleClips[indexes.lowerBound].id
        selectedIDs = Set(indexes.map { visibleClips[$0].id })
        applySelection(scroll: false)
    }
    /// 第 index 张卡片单元的左边相对视口左边的距离。
    func debugCardOffset(index: Int) -> CGFloat? {
        guard let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { return nil }
        return frame.minX - scrollView.contentView.bounds.minX
    }
    /// 把第 index 张卡片滚到视口里离左边 `offset` 的位置。
    func debugScroll(toCard index: Int, offset: CGFloat) {
        guard let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { return }
        scrollView.contentView.scroll(to: NSPoint(x: frame.minX - offset, y: scrollView.contentView.bounds.minY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    var debugScrollX: CGFloat { scrollView.contentView.bounds.minX }
    /// 删除这一段时记下的对齐位置（第一张在眼前的被删卡片，露出一截也算）。
    func debugDeleteAnchorOffset(_ indexes: ClosedRange<Int>) -> CGFloat? { deleteAnchorOffset(for: Array(indexes)) }

    var debugPreviewClipID: ClipSummary.ID? { preview.isShown ? preview.clipID : nil }
    var debugPreviewAwaitsImage: Bool { preview.awaitsImage }
    var debugPreviewShowsImage: Bool { preview.showsImage }
    var debugPreviewText: NSAttributedString? { preview.shownText }
    /// 按住第 index 张卡片起拖时，拖放剪贴板上的内容：写进一个临时剪贴板再读出来，数据提供者会被真正调用。
    func debugDragPasteboard(at index: Int) -> [NSPasteboardItem] {
        let board = NSPasteboard(name: .init("com.mars.XPaste.selftest-drag-\(UUID().uuidString)"))
        board.clearContents()
        board.writeObjects(dragWriters(for: draggedClips(pressed: index)))
        return board.pasteboardItems ?? []
    }
    var debugEditor: EditorController { editor }
    func debugEditSelection() { editSelection() }
    /// 走一遍“拖到第 index 张前面”的落点处理。
    func debugReorder(ids: [Int64], before index: Int) -> Bool {
        guard case .pinboard(let listID) = scope else { return false }
        let target = visibleClips.indices.contains(index) ? visibleClips[index].id : nil
        guard (try? store.movePinned(ids: ids, in: listID, before: target)) != nil else { return false }
        reload(selectFirst: false)
        return true
    }
    var debugVisiblePreviews: [String] { visibleClips.map(\.previewText) }
    /// 集合视图里的卡片数和数据条数一致，屏幕上每张卡片的朗读文字都对应同位置的数据（局部更新后核对用）。
    var debugCardsMatchData: Bool {
        guard collectionView.numberOfItems(inSection: 0) == visibleClips.count else { return false }
        let now = Date()
        return collectionView.indexPathsForVisibleItems().allSatisfy { path in
            guard let card = collectionView.item(at: path) as? ClipCardItem, visibleClips.indices.contains(path.item) else { return false }
            return card.accessibilityLabel() == ClipCardItem.accessibilityLabel(for: visibleClips[path.item], now: now)
        }
    }
    /// 按 clipID 核对卡片身份：屏幕上（和视口有交集）的每张卡片，显示的条目是否就是它所在序号的数据。
    /// 返回对不上的“序号：卡片 → 应为”，空表示全部对得上。不等动画，调用那一刻是什么就核对什么。
    var debugOnScreenIdentityMismatches: [String] {
        let visible = scrollView.contentView.bounds
        return collectionView.visibleItems().compactMap { item -> String? in
            guard let card = item as? ClipCardItem, !card.view.isHidden, card.view.alphaValue > 0,
                  card.view.frame.intersects(visible) else { return nil }
            guard let path = collectionView.indexPath(for: item) else { return "无序号：\(String(describing: card.clipID))" }
            guard visibleClips.indices.contains(path.item) else { return "\(path.item)：超出数据" }
            return card.clipID == visibleClips[path.item].id ? nil
                : "\(path.item)：\(String(describing: card.clipID)) → \(visibleClips[path.item].id)"
        }
    }
    /// 视口里应该看到的序号都有卡片（滚动后布局过一次再看）。
    var debugOnScreenItemCount: Int {
        let visible = scrollView.contentView.bounds
        return collectionView.visibleItems().filter { $0.view.frame.intersects(visible) }.count
    }
    var debugLastApplyMs: Double { lastApplyDuration * 1000 }
    /// 量一次布局加显示（批量更新、重配卡片的实际排版和绘制都在这里发生）。
    func debugMeasureLayoutMs() -> Double {
        let started = CACurrentMediaTime()
        debugForceLayout()
        return (CACurrentMediaTime() - started) * 1000
    }
    /// 整表重载一次（对照用）：返回重载加布局显示的毫秒数。
    func debugMeasureReloadDataMs() -> Double {
        let started = CACurrentMediaTime()
        collectionView.reloadData()
        applySelection(scroll: false)
        debugForceLayout()
        return (CACurrentMediaTime() - started) * 1000
    }
    func debugScroll(toX x: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: x, y: scrollView.contentView.bounds.minY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    /// 卡片和数据对不上的地方（诊断用）：集合视图条目数、数据条数，以及对不上的可见卡片“序号：卡片朗读 ≠ 数据”。
    var debugCardMismatches: String {
        let now = Date()
        let rows = collectionView.indexPathsForVisibleItems().sorted().compactMap { path -> String? in
            guard let card = collectionView.item(at: path) as? ClipCardItem else { return "\(path.item)：无卡片" }
            guard visibleClips.indices.contains(path.item) else { return "\(path.item)：超出数据" }
            let label = card.accessibilityLabel() ?? "", expected = ClipCardItem.accessibilityLabel(for: visibleClips[path.item], now: now)
            return label == expected ? nil : "\(path.item)：\(label.prefix(12)) ≠ \(expected.prefix(12))"
        }
        return "条目 \(collectionView.numberOfItems(inSection: 0)) 数据 \(visibleClips.count) " + rows.joined(separator: "；")
    }
    /// 每个落点（第 i 张之前，最后一个是末尾）的竖线位置，以及卡片的位置。
    var debugDropGaps: (gaps: [NSRect], items: [NSRect]) {
        let count = visibleClips.count
        return ((0...count).map { layout.layoutAttributesForInterItemGap(before: IndexPath(item: $0, section: 0))?.frame ?? .zero },
                (0..<count).map { layout.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame ?? .zero })
    }
    /// 和在搜索框里打字一样：改搜索词并发起查询，不等结果。
    func debugSearch(_ text: String) {
        searchField.stringValue = text
        reload(selectFirst: true)
    }
    var debugQueryPending: Bool { queryTask != nil }
    var debugScrollView: NSScrollView { scrollView }
    /// 等后台列表查询和分页加载都结束。自检在读取列表前调用。
    func debugSettle() async {
        while let task = queryTask { await task.value }
        while let task = previewImageTask { await task.value }
        while let task = textLoadTask { await task.value }
        while loadingMore { try? await Task.sleep(for: .milliseconds(5)) }
    }
    func debugBeginComposition(_ text: String) -> Bool {
        focusSearch()
        guard let editor = searchField.currentEditor() as? NSTextView else { return false }
        editor.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        return editor.hasMarkedText()
    }
    var debugScope: ClipQuery.Scope { scope }
    var debugToolbar: ToolbarView { toolbar }
    func debugSelect(scope: ClipQuery.Scope) { select(scope: scope) }
    var debugPreviewSize: NSSize? { preview.isShown ? preview.window?.contentView?.frame.size : nil }

    /// 按卡片区收到按键的路径处理一次按键。
    func debugPress(keyCode: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: panel.windowNumber,
                                           context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { return }
        _ = handleKey(event)
    }

    /// 按面板窗口收到快捷键的路径处理（先于第一响应者）。
    func debugPerformKeyEquivalent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: panel.windowNumber,
                                           context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode) else { return false }
        return panel.performKeyEquivalent(with: event)
    }
    func debugFocusSearch(_ text: String) {
        searchField.stringValue = text
        focusSearch()
    }

    /// 把面板和预览浮层当前的样子离屏画成 PNG。锁屏或无人值守时用来检查版式；网页和快速查看的内容画不出来。
    func debugSnapshot(to directory: URL, name: String) {
        for (suffix, view) in [("panel", panel.contentView), ("preview", preview.window?.contentView)] {
            guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }

    func debugForceLayout() {
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()
    }
}
#endif

/// Pinboard 菜单里的一行色块。当前颜色外圈描边；每个色块是一个按钮，VoiceOver 读颜色名。
@MainActor
final class ColorSwatchRow: NSView {
    private static let names = [String(localized: "红色"), String(localized: "橙色"), String(localized: "黄色"), String(localized: "绿色"),
                                String(localized: "蓝色"), String(localized: "紫色"), String(localized: "粉色"), String(localized: "灰色")]

    init(colors: [String], selected: String, onPick: @escaping (String) -> Void) {
        let size: CGFloat = 18, gap: CGFloat = 6, inset: CGFloat = 16
        super.init(frame: NSRect(x: 0, y: 0, width: inset * 2 + CGFloat(colors.count) * size + CGFloat(colors.count - 1) * gap, height: 30))
        for (index, hex) in colors.enumerated() {
            let isSelected = hex.caseInsensitiveCompare(selected) == .orderedSame
            let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                (NSColor(hex: hex) ?? .gray).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
                if isSelected {
                    NSColor.labelColor.withAlphaComponent(0.6).setStroke()
                    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                    ring.lineWidth = 1.5
                    ring.stroke()
                }
                return true
            }
            let button = ClosureButton(image: image) { onPick(hex) }
            button.isBordered = false
            button.frame = NSRect(x: inset + CGFloat(index) * (size + gap), y: 6, width: size, height: size)
            button.setAccessibilityLabel(index < Self.names.count ? Self.names[index] : hex)
            button.setAccessibilityValue(isSelected)
            addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class ClosureButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(image: NSImage, handler: @escaping () -> Void) {
        self.init(image: image, target: nil, action: nil)
        self.handler = handler
        target = self
        action = #selector(run)
    }

    @objc private func run() { handler?() }
}

/// 横向一排时流式布局把每张卡片算作单独一“行”，卡片之间没有“行内空隙”，
/// 系统给的落点位置是 0×0，竖线从不出现。按相邻卡片的位置自己算。
final class CardsFlowLayout: NSCollectionViewFlowLayout {
    override func layoutAttributesForInterItemGap(before indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        let count = collectionView?.numberOfItems(inSection: indexPath.section) ?? 0
        guard count > 0 else { return nil }
        let frame: NSRect
        if indexPath.item < count, let next = layoutAttributesForItem(at: indexPath)?.frame {
            frame = NSRect(x: next.minX - minimumLineSpacing, y: next.minY, width: minimumLineSpacing, height: next.height)
        } else if let last = layoutAttributesForItem(at: IndexPath(item: count - 1, section: indexPath.section))?.frame {
            frame = NSRect(x: last.maxX, y: last.minY, width: minimumLineSpacing, height: last.height)
        } else {
            return nil
        }
        let attributes = NSCollectionViewLayoutAttributes(forInterItemGapBefore: indexPath)
        attributes.frame = frame
        attributes.zIndex = 1
        return attributes
    }
}

/// Pinboard 里拖动排序时的落点：卡片之间的一条竖线（原版如此，L36）。
final class DropIndicatorView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("DropIndicator")

    override func draw(_ dirtyRect: NSRect) {
        let width: CGFloat = 3
        let line = NSRect(x: bounds.midX - width / 2, y: bounds.minY + 4, width: width, height: max(0, bounds.height - 8))
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: line, xRadius: width / 2, yRadius: width / 2).fill()
    }
}
