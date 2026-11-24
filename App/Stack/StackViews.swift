import AppKit
import PasteCore

/// Stack 窗口里的列表：每一项是一张圆角卡片，可以双击插队粘贴、点 × 删除、拖动排序、拖到别的应用，
/// 也接收别的应用和面板拖进来的内容（Docs/验收记录/Stack改版.md S2、S5、S6、S8、S11、S12）。
@MainActor
final class StackListView: NSView {
    /// 一行要显示的内容。
    struct Row: Equatable {
        enum Accessory: Equatable {
            case none
            /// 铺满右侧方块（图片、链接配图）。
            case cover(NSImage)
            /// 居中的小图（网站图标、文件图标），底下垫浅灰。
            case icon(NSImage)
            /// 灰色的系统符号（没有网站图标的链接）。
            case symbol(String)
            case color(NSColor)
        }
        let uid: Int
        let text: NSAttributedString
        let accessory: Accessory
        let accessibilityLabel: String
    }

    /// 最上面的一行说明（没有授权时），点了做 `action`。
    struct Notice {
        let text: String
        let action: () -> Void
    }

    static let width: CGFloat = StackController.width
    static let inset: CGFloat = 10
    /// 第一行上面留的空：× 压在卡片右上角、有一半在卡片外面，第一行的不能被裁掉。
    static let topInset: CGFloat = 6
    static let spacing: CGFloat = 6
    static let minRowHeight: CGFloat = 44
    static let accessoryWidth: CGFloat = 44
    static let font = NSFont.systemFont(ofSize: 13)
    static let rowType = NSPasteboard.PasteboardType("com.mars.XPaste.stack-row")
    static let removeSide: CGFloat = 18

    var onDoubleClick: ((Int) -> Void)?
    var onRemove: ((Int) -> Void)?
    /// 把一行挪到第几位（挪完之后的位置）。
    var onMove: ((Int, Int) -> Void)?
    /// 面板卡片拖进来：条目 ID 和放下的位置。
    var onDropIDs: (([Int64], Int) -> Void)?
    /// 别的应用拖进来：返回是否收下。
    var onDropExternal: ((NSPasteboard, Int) -> Bool)?
    /// 一行被拖到别的地方并且对方收下了。
    var onDraggedOut: ((Int) -> Void)?
    /// 拖出一行时放进拖动剪贴板的数据。
    var dragItem: ((Int) -> NSPasteboardItem?)?

    private(set) var rows: [Row] = []
    private var notice: Notice?
    private var placeholder: String?
    private var rowViews: [Int: StackRowView] = [:]
    private let noticeView = StackNoticeView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let insertionLine = NSView()
    /// 指针所在那一行右上角的 ×（原版视频 00:16、00:18）。放在列表上而不是行里，才能有一半露在卡片外面。
    private let removeButton = StackRemoveButton()
    private var hoveredUID: Int? { didSet { if hoveredUID != oldValue { placeRemoveButton() } } }

    /// 正在拖的本窗口的行；拖动期间它的位置空着。
    private var draggingUID: Int?
    /// 拖动经过窗口时要放下的位置；本窗口的行按它让出空位，外来的内容在这里画一条插入线。
    private var dropIndex: Int?
    private var droppedInside = false
    /// false 是拖动中按了 Esc：什么操作都不允许，任何目标都不会接收（同面板卡片，L110）。
    private var dragAllowed = true
    private var dragWatch: Timer?
    private var dragSession: NSDraggingSession?
    /// 起拖那一行的宽度，取消时的云团按它定大小。
    private var dragSide: CGFloat = 0
    private var mouseDownUID: Int?
    private var mouseDownPoint: NSPoint = .zero

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// 窗口可以按背景拖动，列表里按住拖动是排序和拖出，不是挪窗口。
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        placeholderLabel.font = Self.font
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.isHidden = true
        addSubview(placeholderLabel)
        noticeView.isHidden = true
        addSubview(noticeView)
        insertionLine.wantsLayer = true
        insertionLine.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        insertionLine.layer?.cornerRadius = 1
        insertionLine.isHidden = true
        addSubview(insertionLine)
        removeButton.target = self
        removeButton.action = #selector(removeClicked)
        removeButton.toolTip = String(localized: "从 Stack 移除")
        removeButton.isHidden = true
        addSubview(removeButton)
        registerForDraggedTypes([Self.rowType, ClipDrag.idsType, .string, .rtf, .html, .png, .tiff, .fileURL, .URL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(rows: [Row], notice: Notice?, placeholder: String?) {
        self.rows = rows
        self.notice = notice
        self.placeholder = rows.isEmpty ? placeholder : nil
        let live = Set(rows.map(\.uid))
        for (uid, view) in rowViews where !live.contains(uid) {
            view.removeFromSuperview()
            rowViews[uid] = nil
        }
        for row in rows {
            let view = rowViews[row.uid] ?? {
                let view = StackRowView()
                addSubview(view, positioned: .below, relativeTo: insertionLine)
                rowViews[row.uid] = view
                return view
            }()
            if view.row != row { view.row = row }
        }
        if let hoveredUID, !live.contains(hoveredUID) { self.hoveredUID = nil }
        noticeView.isHidden = notice == nil
        noticeView.text = notice?.text ?? ""
        placeholderLabel.isHidden = self.placeholder == nil
        placeholderLabel.stringValue = self.placeholder ?? ""
        layoutRows(animated: false)
    }

    /// 内容的总高度，窗口按它定高。
    var contentHeight: CGFloat {
        var height = Self.topInset
        if notice != nil { height += StackNoticeView.height(for: noticeView.text) + Self.spacing }
        if rows.isEmpty { height += placeholder == nil ? 0 : Self.minRowHeight }
        for row in rows { height += Self.height(of: row) + Self.spacing }
        return height + Self.inset - (rows.isEmpty ? 0 : Self.spacing)
    }

    static func height(of row: Row) -> CGFloat {
        let textWidth = width - inset * 2 - 24 - (row.accessory == .none ? 0 : accessoryWidth)
        let bounds = row.text.boundingRect(with: NSSize(width: textWidth, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        // 最多两行；富文本里的大字号也按两行的高度封顶。
        let text = min(ceil(bounds.height), max(lineHeight * 2, 34))
        return max(minRowHeight, text + 22)
    }

    private var firstRowY: CGFloat {
        Self.topInset + (notice == nil ? 0 : StackNoticeView.height(for: noticeView.text) + Self.spacing)
    }

    private func layoutRows(animated: Bool) {
        let rowWidth = Self.width - Self.inset * 2
        if notice != nil {
            noticeView.frame = NSRect(x: Self.inset, y: Self.topInset, width: rowWidth, height: StackNoticeView.height(for: noticeView.text))
        }
        var y = firstRowY
        if rows.isEmpty, placeholder != nil {
            let height = placeholderLabel.sizeThatFits(NSSize(width: rowWidth, height: 100)).height
            placeholderLabel.frame = NSRect(x: Self.inset, y: y + ((Self.minRowHeight - height) / 2).rounded(), width: rowWidth, height: height)
        }
        insertionLine.isHidden = true
        var visibleIndex = 0
        let gap = draggingUID.flatMap { uid in rows.first { $0.uid == uid } }.map { Self.height(of: $0) + Self.spacing }
        for row in rows {
            guard let view = rowViews[row.uid] else { continue }
            if row.uid == draggingUID {
                view.isHidden = true
                continue
            }
            if visibleIndex == dropIndex {
                if let gap { y += gap } else { showInsertionLine(at: y - Self.spacing / 2) }
            }
            view.isHidden = false
            let frame = NSRect(x: Self.inset, y: y, width: rowWidth, height: Self.height(of: row))
            if animated { view.animator().frame = frame } else { view.frame = frame }
            y += frame.height + Self.spacing
            visibleIndex += 1
        }
        if dropIndex == visibleIndex, gap == nil, dropIndex != nil { showInsertionLine(at: y - Self.spacing / 2) }
        placeRemoveButton()
    }

    private func showInsertionLine(at y: CGFloat) {
        insertionLine.isHidden = false
        insertionLine.frame = NSRect(x: Self.inset + 4, y: max(0, y - 1), width: Self.width - Self.inset * 2 - 8, height: 2)
    }

    // MARK: 指针悬停与 ×

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { hoveredUID = nil }

    private func updateHover(_ event: NSEvent) {
        guard draggingUID == nil else { hoveredUID = nil; return }
        let point = convert(event.locationInWindow, from: nil)
        // 指针挪到露在卡片外面的那半个 × 上，仍算在这一行上。
        if !removeButton.isHidden, removeButton.frame.contains(point) { return }
        hoveredUID = uid(at: point)
    }

    /// × 压在卡片右上角，圆心在角内一点，有一半露在卡片外面（原版视频 00:16、00:18）。
    private func placeRemoveButton() {
        guard draggingUID == nil, let hoveredUID, let view = rowViews[hoveredUID], !view.isHidden else {
            removeButton.isHidden = true
            removeButton.resetHover()
            return
        }
        let side = Self.removeSide
        removeButton.baseFrame = NSRect(x: view.frame.maxX - side / 2 - 4, y: view.frame.minY - side / 2 + 4, width: side, height: side)
        removeButton.isHidden = false
    }

    @objc private func removeClicked() {
        guard let hoveredUID else { return }
        self.hoveredUID = nil
        onRemove?(hoveredUID)
    }

    // MARK: 点按

    private func uid(at point: NSPoint) -> Int? {
        rowViews.first { !$0.value.isHidden && $0.value.frame.contains(point) }?.key
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let notice, !noticeView.isHidden, noticeView.frame.contains(point) {
            notice.action()
            return
        }
        mouseDownUID = uid(at: point)
        mouseDownPoint = point
        if event.clickCount == 2, let uid = mouseDownUID {
            mouseDownUID = nil
            onDoubleClick?(uid)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let uid = mouseDownUID, let view = rowViews[uid] else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) > 3, let item = dragItem?(uid) else { return }
        mouseDownUID = nil
        item.setString(String(uid), forType: Self.rowType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(view.frame, contents: view.snapshot())
        draggingUID = uid
        hoveredUID = nil
        droppedInside = false
        dragAllowed = true
        dragSide = view.frame.width
        dropIndex = rows.firstIndex { $0.uid == uid }
        layoutRows(animated: false)
        let session = beginDraggingSession(with: [dragging], event: event, source: self)
        // 取消、没放下时不飞回原位，在松手处冒一团云（同面板卡片，L147）。
        session.animatesToStartingPositionsOnCancelOrFail = false
        watchEscape(session)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownUID = nil
    }

    /// 拖动中按 Esc 取消（同面板卡片，L110）：拖动循环里按键事件不一定送到这里，直接看键盘状态。
    /// 别的应用只在拖动开始时问一次允许什么操作，中途改不管用；把拖动带的内容清空，它们松手时读不到东西。
    private func watchEscape(_ session: NSDraggingSession) {
        dragWatch?.invalidate()
        dragSession = session
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.dragAllowed, CGEventSource.keyState(.combinedSessionState, key: 53) else { return }
                self.dragAllowed = false
                self.dragSession?.draggingPasteboard.clearContents()
                self.dropIndex = nil
                self.layoutRows(animated: true)
                // 系统多半已经自己取消了；0.1 秒后会话还在就主动结束（和面板卡片同一个办法）。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    if self?.dragSession != nil { DragCancellation.endDragNow() }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragWatch = timer
    }

    override func resetCursorRects() {
        if notice != nil, !noticeView.isHidden { addCursorRect(noticeView.frame, cursor: .pointingHand) }
    }

    // MARK: 放下

    /// 放在第几位：按指针落在哪一行的上半还是下半算，拖着的那一行不计。
    private func insertionIndex(for sender: NSDraggingInfo) -> Int {
        let point = convert(sender.draggingLocation, from: nil)
        let visible = rows.filter { $0.uid != draggingUID }.compactMap { rowViews[$0.uid] }
        // 拖动中各行会让位，用不让位时的位置算，免得空位跟着指针来回跳。
        var y = firstRowY
        for (index, view) in visible.enumerated() {
            let height = view.frame.height
            if point.y < y + height / 2 { return index }
            y += height + Self.spacing
        }
        return visible.count
    }

    private func kind(of sender: NSDraggingInfo) -> NSDragOperation {
        let types = sender.draggingPasteboard.types ?? []
        if (sender.draggingSource as? StackListView) === self { return dragAllowed && draggingUID != nil ? .move : [] }
        if types.contains(ClipDrag.idsType) { return .copy }
        return sender.draggingSource == nil ? .copy : []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = kind(of: sender)
        guard !operation.isEmpty else { return [] }
        let index = insertionIndex(for: sender)
        if index != dropIndex {
            dropIndex = index
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.allowsImplicitAnimation = true
                layoutRows(animated: true)
            }
        }
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropIndex = nil
        NSAnimationContext.runAnimationGroup { _ in layoutRows(animated: true) }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let operation = kind(of: sender)
        guard !operation.isEmpty else { return false }
        let index = insertionIndex(for: sender)
        dropIndex = nil
        defer { layoutRows(animated: false) }
        if operation == .move, let uid = draggingUID {
            droppedInside = true
            draggingUID = nil
            onMove?(uid, index)
            return true
        }
        let ids = ClipDrag.ids(from: sender.draggingPasteboard)
        if !ids.isEmpty {
            onDropIDs?(ids, index)
            return true
        }
        return onDropExternal?(sender.draggingPasteboard, index) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        dropIndex = nil
        layoutRows(animated: false)
    }

    #if DEBUG
    var debugRowFrames: [NSRect] { rows.compactMap { rowViews[$0.uid]?.frame } }
    /// 指针移到第几行上，返回 × 的位置（列表坐标）；没有这一行时返回 nil。
    func debugHover(row index: Int) -> NSRect? {
        guard rows.indices.contains(index) else { return nil }
        hoveredUID = rows[index].uid
        return removeButton.isHidden ? nil : removeButton.frame
    }
    func debugClickRemove() { removeClicked() }
    /// 指针移到 × 上：返回放大后的大小和是否换了样子。
    func debugHoverRemoveButton() -> (frame: NSRect, hovering: Bool) {
        removeButton.debugHover(true)
        defer { removeButton.debugHover(false) }
        return (removeButton.frame, removeButton.hovering)
    }
    /// 走一遍拖动结束的处理；返回是否冒了云团。
    func debugEndDrag(uid: Int, operation: NSDragOperation, escaped: Bool = false) -> Bool {
        draggingUID = uid
        dragAllowed = !escaped
        dragSide = Self.width - Self.inset * 2
        return finishDrag(at: .zero, operation: operation, showEffect: false)
    }
    #endif
}

extension StackListView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        guard dragAllowed else { return [] }
        return context == .withinApplication ? [.move, .copy, .generic] : [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        finishDrag(at: screenPoint, operation: operation, showEffect: true)
    }

    /// 拖动结束：对方收下了就交给 `onDraggedOut`（这一行离开 Stack）；取消、没放下、按了 Esc 就在松手处冒一团云，这一行留在原处。
    /// 返回是否冒了云团。
    @discardableResult
    private func finishDrag(at screenPoint: NSPoint, operation: NSDragOperation, showEffect: Bool) -> Bool {
        dragWatch?.invalidate()
        dragWatch = nil
        dragSession = nil
        let uid = draggingUID
        let accepted = dragAllowed && !operation.isEmpty
        draggingUID = nil
        dropIndex = nil
        defer {
            droppedInside = false
            dragAllowed = true
        }
        guard !droppedInside, let uid else {
            layoutRows(animated: false)
            return false
        }
        if accepted {
            onDraggedOut?(uid)
            return false
        }
        layoutRows(animated: false)
        if showEffect { PanelController.poof(at: screenPoint, cardSide: dragSide) }
        return true
    }
}

/// 行右上角的 ×：指针移上去时略微放大、颜色反过来（深底浅叉 ↔ 浅底深叉），表示点它会删掉这一行。
@MainActor
final class StackRemoveButton: StackButton {
    /// 不悬停时的位置和大小；悬停时以它为中心放大 `growth`。
    var baseFrame: NSRect = .zero { didSet { frame = hovering ? grown : baseFrame } }
    static let growth: CGFloat = 2.5
    private(set) var hovering = false
    private var grown: NSRect { baseFrame.insetBy(dx: -Self.growth, dy: -Self.growth) }

    private static func image(hovering: Bool) -> NSImage? {
        let colors: [NSColor] = hovering
            ? [NSColor.windowBackgroundColor, NSColor.labelColor]
            : [.secondaryLabelColor, NSColor.windowBackgroundColor.withAlphaComponent(0.92)]
        return NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: String(localized: "从 Stack 移除"))?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular).applying(.init(paletteColors: colors)))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        image = Self.image(hovering: false)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyUpOrDown
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    func resetHover() {
        hovering = false
        image = Self.image(hovering: false)
        frame = baseFrame
    }

    private func setHovering(_ value: Bool) {
        guard value != hovering else { return }
        hovering = value
        image = Self.image(hovering: value)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().frame = value ? grown : baseFrame
        }
    }

    #if DEBUG
    func debugHover(_ value: Bool) { setHovering(value) }
    #endif
}

/// 一张卡片：左边文字最多两行，右边可能有缩略图、网站图标或色块。
@MainActor
final class StackRowView: NSView {
    static let cornerRadius: CGFloat = 13

    var row: StackListView.Row? { didSet { apply() } }

    private let label = NSTextField(wrappingLabelWithString: "")
    private let accessory = NSView()
    private let accessoryImage = NSImageView()

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        label.isSelectable = false
        label.font = StackListView.font
        label.maximumNumberOfLines = 2
        label.cell?.truncatesLastVisibleLine = true
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        accessory.wantsLayer = true
        accessory.layer?.contentsGravity = .resizeAspectFill
        addSubview(accessory)
        accessoryImage.imageScaling = .scaleProportionallyUpOrDown
        accessory.addSubview(accessoryImage)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 点按都交给列表处理（双击、拖动）。
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { superview?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { superview?.mouseUp(with: event) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        apply()
    }

    private static let cardColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.white.withAlphaComponent(0.12) : NSColor.white.withAlphaComponent(0.9)
    }
    private static let wellColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.04)
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.cardColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
    }

    private func apply() {
        guard let row else { return }
        label.attributedStringValue = row.text
        setAccessibilityLabel(row.accessibilityLabel)
        accessory.isHidden = row.accessory == .none
        accessory.layer?.contents = nil
        accessory.layer?.backgroundColor = Self.wellColor.cgColor
        accessoryImage.isHidden = true
        accessoryImage.contentTintColor = nil
        switch row.accessory {
        case .none: break
        case .cover(let image):
            accessory.layer?.contents = image
        case .icon(let image):
            accessoryImage.isHidden = false
            accessoryImage.image = image
        case .symbol(let name):
            accessoryImage.isHidden = false
            accessoryImage.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            accessoryImage.contentTintColor = .tertiaryLabelColor
        case .color(let color):
            accessory.layer?.backgroundColor = color.cgColor
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let row else { return }
        let trailing = row.accessory == .none ? 0 : StackListView.accessoryWidth
        let textWidth = bounds.width - 24 - trailing
        let height = min(label.sizeThatFits(NSSize(width: textWidth, height: 1000)).height, bounds.height - 16)
        label.frame = NSRect(x: 12, y: ((bounds.height - height) / 2).rounded(), width: textWidth, height: height)
        accessory.frame = NSRect(x: bounds.width - StackListView.accessoryWidth, y: 0, width: StackListView.accessoryWidth, height: bounds.height)
        accessoryImage.frame = accessory.bounds.insetBy(dx: (accessory.bounds.width - 22) / 2, dy: (accessory.bounds.height - 22) / 2)
    }

    /// 拖动时跟着指针走的图：这一行的样子，带圆角。
    func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return image }
        cacheDisplay(in: bounds, to: rep)
        image.addRepresentation(rep)
        // 缩略图和色块画在图层上，`cacheDisplay` 画不出来，另外补上。
        guard let row, row.accessory != .none else { return image }
        image.lockFocusFlipped(true)
        let rect = accessory.frame
        NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).addClip()
        switch row.accessory {
        case .cover(let picture):
            let scale = max(rect.width / max(picture.size.width, 1), rect.height / max(picture.size.height, 1))
            let size = NSSize(width: picture.size.width * scale, height: picture.size.height * scale)
            NSBezierPath(rect: rect).addClip()
            picture.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case .color(let color):
            color.setFill()
            rect.fill()
        default: break
        }
        image.unlockFocus()
        return image
    }
}

/// 没有授权时最上面那一行：警告图标加说明，点了打开系统设置。
@MainActor
final class StackNoticeView: NSView {
    var text = "" { didSet { label.stringValue = text; needsLayout = true } }
    private let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) ?? NSImage())
    private let label = NSTextField(wrappingLabelWithString: "")

    override var isFlipped: Bool { true }

    static func height(for text: String) -> CGFloat {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = StackListView.font
        return max(StackListView.minRowHeight, ceil(field.sizeThatFits(NSSize(width: textWidth, height: 1000)).height) + 16)
    }
    static let textWidth = StackListView.width - StackListView.inset * 2 - 36

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.contentTintColor = .secondaryLabelColor
        label.font = StackListView.font
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        addSubview(icon)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        setAccessibilityLabel(text)
        icon.frame = NSRect(x: 4, y: ((bounds.height - 14) / 2).rounded(), width: 14, height: 14)
        let height = label.sizeThatFits(NSSize(width: Self.textWidth, height: 1000)).height
        label.frame = NSRect(x: 24, y: ((bounds.height - height) / 2).rounded(), width: Self.textWidth, height: height)
    }
}

/// 窗口不是 key 窗口、应用也不在前台，普通按钮会把第一次点击只当成激活；这里让它单击即生效。
class StackButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
