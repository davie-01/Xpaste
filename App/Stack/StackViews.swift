import AppKit
import PasteCore

/// Stack 窗口里的列表：每一项是一张圆角卡片，可以双击插队粘贴、点 × 删除、拖动排序、拖到别的应用，
/// 也接收别的应用和面板拖进来的内容（Docs/归档/验收记录/Stack改版.md S2、S5、S6、S8、S11、S12）。
///
/// 交互动画（用户真机第二轮，2026-11-24）：
/// - 指针移到哪张卡片上，它略微放大、提亮，带一层柔和的阴影；
/// - 在窗口里拖动排序时拖的是卡片本身：它浮起来（更大、阴影更重）跟着指针上下走，其余卡片平滑地让位，松手后缓缓落进空位；
///   卡片是实心的，浮起的那张盖住下面的，文字不会叠在一起看不清；
/// - 指针拖出窗口才转成系统拖拽（拖进别的应用），取消时在松手处冒云团。
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
    /// 第一行上面留的空：× 压在卡片右上角、有一部分在卡片外面，悬停时卡片还会放大，第一行的不能被裁掉。
    static let topInset: CGFloat = 8
    static let spacing: CGFloat = 6
    static let minRowHeight: CGFloat = 44
    static let accessoryWidth: CGFloat = 44
    static let font = NSFont.systemFont(ofSize: 13)
    static let rowType = NSPasteboard.PasteboardType("com.mars.XPaste.stack-row")
    static let removeSide: CGFloat = 14
    /// 悬停和浮起时卡片每边放大多少。
    static let hoverGrowth = NSSize(width: 2, height: 1.5)
    static let liftGrowth = NSSize(width: 4, height: 3)
    /// 让位、落位的动画：0.24 秒，开头快、结尾慢慢停住。
    static let slideDuration: TimeInterval = 0.24
    static let slideTiming = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1)

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
    /// 指针所在那一行右上角的 ×。放在列表上而不是行里，才能有一部分露在卡片外面。
    private let removeButton = StackRemoveButton()
    private var hoveredUID: Int? {
        didSet { if hoveredUID != oldValue { layoutRows(animated: true) } }
    }

    /// 在窗口里拖动排序的那一行（卡片本身跟着指针走）。
    private var liftedUID: Int?
    /// 按下时指针离卡片上边多远，拖动时保持不变。
    private var grabOffset: CGFloat = 0
    /// 正在拖的本窗口的行（窗口里拖着或已转成系统拖拽）；它原来的位置按 `dropIndex` 空出来。
    private var draggingUID: Int?
    /// 要放下的位置：本窗口的行按它让出空位，外来的内容在这里画一条插入线。
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

    // MARK: 布局

    /// 各行不放大、不让位时的位置（列表从上到下排，拖着的那一行不计）。
    private func restingFrames(skipping skipped: Int?) -> [(uid: Int, frame: NSRect)] {
        var y = firstRowY
        var result: [(Int, NSRect)] = []
        for row in rows where row.uid != skipped {
            let height = Self.height(of: row)
            result.append((row.uid, NSRect(x: Self.inset, y: y, width: Self.width - Self.inset * 2, height: height)))
            y += height + Self.spacing
        }
        return result
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
        var targets: [(StackRowView, NSRect, StackRowView.Emphasis)] = []
        for row in rows {
            guard let view = rowViews[row.uid] else { continue }
            if row.uid == draggingUID {
                // 窗口里拖着的那张跟着指针走（位置由拖动处理来定）；转成系统拖拽后藏起来，位置空着。
                view.isHidden = liftedUID != row.uid
                continue
            }
            if visibleIndex == dropIndex {
                if let gap { y += gap } else { showInsertionLine(at: y - Self.spacing / 2) }
            }
            view.isHidden = false
            let resting = NSRect(x: Self.inset, y: y, width: rowWidth, height: Self.height(of: row))
            let hovered = row.uid == hoveredUID && draggingUID == nil
            let grow = hovered ? Self.hoverGrowth : .zero
            targets.append((view, resting.insetBy(dx: -grow.width, dy: -grow.height), hovered ? .hover : .normal))
            y += resting.height + Self.spacing
            visibleIndex += 1
        }
        if dropIndex == visibleIndex, gap == nil, dropIndex != nil { showInsertionLine(at: y - Self.spacing / 2) }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.slideDuration
                context.timingFunction = Self.slideTiming
                context.allowsImplicitAnimation = true
                for (view, frame, emphasis) in targets {
                    view.animator().frame = frame
                    view.setEmphasis(emphasis, animated: true)
                }
            }
        } else {
            for (view, frame, emphasis) in targets {
                view.frame = frame
                view.setEmphasis(emphasis, animated: false)
            }
        }
        placeRemoveButton(animated: animated)
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
    override func mouseExited(with event: NSEvent) { if draggingUID == nil { hoveredUID = nil } }

    private func updateHover(_ event: NSEvent) {
        guard draggingUID == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        // 指针挪到露在卡片外面的那部分 × 上，仍算在这一行上。
        if !removeButton.isHidden, removeButton.frame.contains(point) { return }
        hoveredUID = uid(at: point)
    }

    /// × 压在卡片右上角，圆心在角内一点（原版视频 00:16、00:18）。跟着悬停放大后的卡片走。
    private func placeRemoveButton(animated: Bool) {
        guard draggingUID == nil, let hoveredUID, let view = rowViews[hoveredUID], !view.isHidden,
              let row = rows.first(where: { $0.uid == hoveredUID }),
              let resting = restingFrames(skipping: nil).first(where: { $0.uid == row.uid })?.frame else {
            removeButton.isHidden = true
            removeButton.resetHover()
            return
        }
        let card = resting.insetBy(dx: -Self.hoverGrowth.width, dy: -Self.hoverGrowth.height)
        let side = Self.removeSide
        removeButton.baseFrame = NSRect(x: card.maxX - side / 2 - 3, y: card.minY - side / 2 + 3, width: side, height: side)
        removeButton.isHidden = false
        _ = animated
    }

    @objc private func removeClicked() {
        guard let hoveredUID else { return }
        self.hoveredUID = nil
        onRemove?(hoveredUID)
    }

    // MARK: 点按与拖动

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
        let point = convert(event.locationInWindow, from: nil)
        if liftedUID != nil {
            // 拖出窗口就转成系统拖拽，好拖进别的应用。
            if let content = window?.contentView, !content.bounds.contains(content.convert(event.locationInWindow, from: nil)) {
                beginDragOut(with: event)
            } else {
                moveLift(to: point)
                autoscroll(with: event)
            }
            return
        }
        guard let uid = mouseDownUID, hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) > 3 else { return }
        mouseDownUID = nil
        beginLift(uid: uid, at: mouseDownPoint)
        moveLift(to: point)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownUID = nil
        if liftedUID != nil { dropLift(animated: true) }
    }

    override func resetCursorRects() {
        if notice != nil, !noticeView.isHidden { addCursorRect(noticeView.frame, cursor: .pointingHand) }
    }

    /// 卡片浮起来：放大、阴影加重，排到最上层；它原来的位置先空着。
    private func beginLift(uid: Int, at point: NSPoint) {
        guard let view = rowViews[uid] else { return }
        liftedUID = uid
        draggingUID = uid
        hoveredUID = nil
        dragAllowed = true
        droppedInside = false
        dropIndex = rows.firstIndex { $0.uid == uid }
        dragSide = view.frame.width
        grabOffset = point.y - view.frame.minY
        // 浮起的卡片要在其他卡片上面，但在 × 和插入线下面。
        addSubview(view, positioned: .below, relativeTo: insertionLine)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.allowsImplicitAnimation = true
            view.animator().frame = liftFrame(for: view, top: view.frame.minY)
            view.setEmphasis(.lifted, animated: true)
        }
        layoutRows(animated: true)
        watchEscape()
    }

    private func liftFrame(for view: StackRowView, top: CGFloat) -> NSRect {
        let height = view.row.map(Self.height(of:)) ?? view.frame.height
        let resting = NSRect(x: Self.inset, y: top, width: Self.width - Self.inset * 2, height: height)
        return resting.insetBy(dx: -Self.liftGrowth.width, dy: -Self.liftGrowth.height)
    }

    /// 浮起的卡片跟着指针上下走（不左右偏），按它的中线算出新位置，其余卡片平滑让位。
    private func moveLift(to point: NSPoint) {
        guard let uid = liftedUID, let view = rowViews[uid] else { return }
        let height = view.row.map(Self.height(of:)) ?? view.frame.height
        let top = min(max(point.y - grabOffset, firstRowY - 6), max(firstRowY, contentHeight - height - Self.inset + 6))
        view.frame = liftFrame(for: view, top: top)
        // 拖着的卡片的中线越过哪张卡片原来的中线，就和它换位（和原来的位置比，不和让位后的比，免得刚一动下面那张就跳上来）。
        let middle = top + height / 2
        var index = 0
        for (other, frame) in restingFrames(skipping: nil) where other != uid && middle > frame.midY { index += 1 }
        if index != dropIndex {
            dropIndex = index
            layoutRows(animated: true)
        }
    }

    /// 松手：卡片缓缓落进空位，落好以后再改顺序（列表刷新时位置一样，不会跳）。
    private func dropLift(animated: Bool) {
        guard let uid = liftedUID, let view = rowViews[uid] else { return }
        dragWatch?.invalidate()
        dragWatch = nil
        let from = rows.firstIndex { $0.uid == uid }
        let to = dragAllowed ? (dropIndex ?? from ?? 0) : (from ?? 0)
        // 空位在第几位，落点就是那一格。
        var slot = firstRowY
        for (index, (_, frame)) in restingFrames(skipping: uid).enumerated() where index < to { slot = frame.maxY + Self.spacing }
        let target = NSRect(x: Self.inset, y: slot, width: Self.width - Self.inset * 2, height: view.row.map(Self.height(of:)) ?? view.frame.height)
        guard animated else {
            view.frame = target
            view.setEmphasis(.normal, animated: false)
            completeLift(uid: uid, from: from, to: to)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.slideDuration
            context.timingFunction = Self.slideTiming
            context.allowsImplicitAnimation = true
            view.animator().frame = target
            view.setEmphasis(.normal, animated: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.completeLift(uid: uid, from: from, to: to) }
        })
    }

    private func completeLift(uid: Int, from: Int?, to: Int) {
        liftedUID = nil
        draggingUID = nil
        dropIndex = nil
        if let from, from != to { onMove?(uid, to) } else { layoutRows(animated: false) }
    }

    /// 拖出窗口：浮起的卡片藏起来，换成系统拖拽（带上条目内容），别的应用可以接。
    private func beginDragOut(with event: NSEvent) {
        guard let uid = liftedUID, let view = rowViews[uid], let item = dragItem?(uid) else { return }
        liftedUID = nil
        item.setString(String(uid), forType: Self.rowType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(view.frame, contents: view.snapshot())
        view.isHidden = true
        view.setEmphasis(.normal, animated: false)
        dropIndex = nil
        layoutRows(animated: true)
        let session = beginDraggingSession(with: [dragging], event: event, source: self)
        // 取消、没放下时不飞回原位，在松手处冒一团云（同面板卡片，L147）。
        session.animatesToStartingPositionsOnCancelOrFail = false
        dragSession = session
    }

    /// 拖动中按 Esc 取消（同面板卡片，L110）：窗口不是 key 窗口，按键送不到这里，直接看键盘状态。
    /// 窗口里拖着时卡片落回原位；已经转成系统拖拽时清空拖动内容、立刻结束会话、冒云团。
    private func watchEscape() {
        dragWatch?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.dragAllowed, CGEventSource.keyState(.combinedSessionState, key: 53) else { return }
                self.dragAllowed = false
                if self.liftedUID != nil {
                    self.dropLift(animated: true)
                    return
                }
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

    // MARK: 放下（别的应用、面板拖进来，或者拖出去又拖回来）

    /// 放在第几位：按指针落在哪一行的上半还是下半算，拖着的那一行不计。
    private func insertionIndex(for sender: NSDraggingInfo) -> Int {
        let point = convert(sender.draggingLocation, from: nil)
        var index = 0
        for (_, frame) in restingFrames(skipping: draggingUID) where point.y > frame.midY { index += 1 }
        return index
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
            layoutRows(animated: true)
        }
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropIndex = nil
        layoutRows(animated: true)
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
        layoutRows(animated: false)
        return removeButton.isHidden ? nil : removeButton.frame
    }
    func debugClickRemove() { removeClicked() }
    /// 指针移到 × 上：返回放大后的大小和是否换了样子。
    func debugHoverRemoveButton() -> (frame: NSRect, hovering: Bool) {
        removeButton.debugHover(true)
        defer { removeButton.debugHover(false) }
        return (removeButton.frame, removeButton.hovering)
    }
    /// 悬停的那一行是不是放大、换成了悬停的样子。
    func debugHoverEmphasis(row index: Int) -> (grown: Bool, emphasis: StackRowView.Emphasis)? {
        guard rows.indices.contains(index), let view = rowViews[rows[index].uid] else { return nil }
        let resting = restingFrames(skipping: nil)[index].frame
        return (view.frame.width > resting.width, view.emphasis)
    }
    /// 走一遍窗口里的拖动排序：按住第 `index` 行，拖到 `y`（列表坐标，卡片中线），中途看各行有没有让位，最后不带动画松手。
    func debugLiftDrag(row index: Int, toMiddle y: CGFloat) -> (liftedOnTop: Bool, dropIndex: Int?) {
        let uid = rows[index].uid
        let frame = rowViews[uid]?.frame ?? .zero
        let grab = NSPoint(x: frame.midX, y: frame.midY)
        beginLift(uid: uid, at: grab)
        moveLift(to: NSPoint(x: grab.x, y: y))
        let liftedIndex = subviews.firstIndex { $0 === rowViews[uid] } ?? -1
        let others = rowViews.filter { $0.key != uid }.compactMap { entry in subviews.firstIndex { $0 === entry.value } }
        let onTop = others.allSatisfy { $0 < liftedIndex }
        let result = (onTop && rowViews[uid]?.emphasis == .lifted, dropIndex)
        dropLift(animated: false)
        return result
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

    /// 系统拖拽结束：对方收下了就交给 `onDraggedOut`（这一行离开 Stack）；取消、没放下、按了 Esc 就在松手处冒一团云，这一行留在原处。
    /// 返回是否冒了云团。
    @discardableResult
    private func finishDrag(at screenPoint: NSPoint, operation: NSDragOperation, showEffect: Bool) -> Bool {
        dragWatch?.invalidate()
        dragWatch = nil
        dragSession = nil
        let uid = draggingUID
        let accepted = dragAllowed && !operation.isEmpty
        draggingUID = nil
        liftedUID = nil
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
        layoutRows(animated: true)
        if showEffect { PanelController.poof(at: screenPoint, cardSide: dragSide) }
        return true
    }
}

/// 一张卡片：左边文字最多两行，右边可能有缩略图、网站图标或色块。
/// 卡片是实心的（深色下也不透），叠在别的卡片上时盖住下面的；阴影画在外层，圆角裁剪在里层。
@MainActor
final class StackRowView: NSView {
    enum Emphasis: Equatable {
        case normal
        /// 指针在上面：略微提亮，带柔和的阴影。
        case hover
        /// 拖动中浮起：阴影更重。
        case lifted
    }

    static let cornerRadius: CGFloat = 13

    var row: StackListView.Row? { didSet { apply() } }
    private(set) var emphasis: Emphasis = .normal

    private let card = StackCardView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let accessory = NSView()
    private let accessoryImage = NSImageView()

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0
        layer?.shadowRadius = 0
        layer?.shadowOffset = .zero
        card.wantsLayer = true
        card.layer?.cornerRadius = Self.cornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.autoresizingMask = [.width, .height]
        addSubview(card)
        label.isSelectable = false
        label.font = StackListView.font
        label.maximumNumberOfLines = 2
        label.cell?.truncatesLastVisibleLine = true
        label.lineBreakMode = .byTruncatingTail
        card.addSubview(label)
        accessory.wantsLayer = true
        accessory.layer?.contentsGravity = .resizeAspectFill
        card.addSubview(accessory)
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
        apply()
        updateShadowPath()
    }

    func setEmphasis(_ value: Emphasis, animated: Bool) {
        guard value != emphasis else { return }
        emphasis = value
        card.highlighted = value != .normal
        let (opacity, radius, offset): (Float, CGFloat, CGFloat) = switch value {
        case .normal: (0, 0, 0)
        case .hover: (0.16, 6, 2)
        case .lifted: (0.3, 14, 7)
        }
        guard let layer else { return }
        let changes = { [weak layer] in
            layer?.shadowOpacity = opacity
            layer?.shadowRadius = radius
            // 翻转坐标的视图里，图层的 y 轴向上：负值是往下落。
            layer?.shadowOffset = CGSize(width: 0, height: -offset)
        }
        if animated {
            for (key, value) in [("shadowOpacity", opacity as Any), ("shadowRadius", radius as Any)] {
                let animation = CABasicAnimation(keyPath: key)
                animation.fromValue = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
                animation.toValue = value
                animation.duration = StackListView.slideDuration
                animation.timingFunction = StackListView.slideTiming
                layer.add(animation, forKey: key)
            }
        }
        changes()
    }

    private func apply() {
        guard let row else { return }
        label.attributedStringValue = row.text
        setAccessibilityLabel(row.accessibilityLabel)
        accessory.isHidden = row.accessory == .none
        accessory.layer?.contents = nil
        accessory.layer?.backgroundColor = StackCardView.wellColor.resolvedCGColor(in: effectiveAppearance)
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
        card.frame = bounds
        updateShadowPath()
        guard let row else { return }
        let trailing = row.accessory == .none ? 0 : StackListView.accessoryWidth
        let textWidth = bounds.width - 24 - trailing
        let height = min(label.sizeThatFits(NSSize(width: textWidth, height: 1000)).height, bounds.height - 16)
        label.frame = NSRect(x: 12, y: ((bounds.height - height) / 2).rounded(), width: textWidth, height: height)
        accessory.frame = NSRect(x: bounds.width - StackListView.accessoryWidth, y: 0, width: StackListView.accessoryWidth, height: bounds.height)
        accessoryImage.frame = accessory.bounds.insetBy(dx: (accessory.bounds.width - 22) / 2, dy: (accessory.bounds.height - 22) / 2)
    }

    private func updateShadowPath() {
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
    }

    /// 拖出窗口时跟着指针走的图：这一行的样子，带圆角。
    func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        guard let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else { return image }
        card.cacheDisplay(in: card.bounds, to: rep)
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

/// 卡片的底：实心圆角块加一圈很细的描边。悬停、浮起时略微提亮。
@MainActor
final class StackCardView: NSView {
    var highlighted = false { didSet { if highlighted != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func fillColor(highlighted: Bool) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? NSColor(white: highlighted ? 0.3 : 0.255, alpha: 1) : NSColor(white: highlighted ? 1 : 0.975, alpha: 1)
        }
    }
    static let borderColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.07)
    }
    static let wellColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.04)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = StackRowView.cornerRadius
        Self.fillColor(highlighted: highlighted).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: r - 0.5, yRadius: r - 0.5)
        border.lineWidth = 1
        Self.borderColor.setStroke()
        border.stroke()
    }
}

private extension NSColor {
    func resolvedCGColor(in appearance: NSAppearance) -> CGColor {
        var color = cgColor
        appearance.performAsCurrentDrawingAppearance { color = self.cgColor }
        return color
    }
}

/// 行右上角的 ×：平时是灰色小圆，指针移上去略微放大、变成暗红色，表示点它会删掉这一行。
@MainActor
final class StackRemoveButton: StackButton {
    /// 不悬停时的位置和大小；悬停时以它为中心放大 `growth`。
    var baseFrame: NSRect = .zero { didSet { frame = hovering ? grown : baseFrame } }
    static let growth: CGFloat = 1.5
    static let closeRed = NSColor(srgbRed: 0.72, green: 0.13, blue: 0.14, alpha: 1)
    private(set) var hovering = false
    private var grown: NSRect { baseFrame.insetBy(dx: -Self.growth, dy: -Self.growth) }

    private static func image(hovering: Bool) -> NSImage? {
        let colors: [NSColor] = hovering
            ? [.white, closeRed]
            : [NSColor.white, NSColor.secondaryLabelColor.withAlphaComponent(0.55)]
        return NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: String(localized: "从 Stack 移除"))?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold).applying(.init(paletteColors: colors)))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        image = Self.image(hovering: false)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.2
        layer?.shadowRadius = 1.5
        layer?.shadowOffset = CGSize(width: 0, height: -0.5)
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
    var debugIsRed: Bool { hovering }
    #endif
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
