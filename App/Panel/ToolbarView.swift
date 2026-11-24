import AppKit
import PasteCore

/// 面板内部拖动卡片时用的私有类型：值是逗号分隔的条目 ID。拖到页签上固定、在 Pinboard 里排序都靠它识别。
enum ClipDrag {
    static let idsType = NSPasteboard.PasteboardType("com.mars.XPaste.clip-ids")

    static func ids(from pasteboard: NSPasteboard) -> [Int64] {
        let parts = (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: idsType) }.flatMap { $0.split(separator: ",") }
        var seen = Set<Int64>()
        return parts.compactMap { Int64($0) }.filter { seen.insert($0).inserted }
    }
}

/// 工具栏里的一个列表页签：选中时带胶囊底色。
@MainActor
final class TabChip: NSView {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    private let icon = NSImageView()
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    var isSelected = false { didSet { needsDisplay = true; updateColors(); setAccessibilityValue(isSelected) } }
    /// 把卡片拖到这个页签上松手时调用，参数是条目 ID。不设就不接收拖放（“剪贴板”页签）。
    var onDropClips: (([Int64]) -> Void)? { didSet { onDropClips == nil ? unregisterDraggedTypes() : registerForDraggedTypes([ClipDrag.idsType]) } }
    private var isDropTarget = false { didSet { updateColors() } }
    /// 搜索展开时页签收成只剩图标或色点。
    var isCollapsed = false { didSet { label.isHidden = isCollapsed } }

    init(title: String, symbol: String? = nil, dotColor: NSColor? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous

        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let symbol {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
            stack.addArrangedSubview(icon)
        }
        if let dotColor {
            dot.wantsLayer = true
            dot.layer?.backgroundColor = dotColor.cgColor
            dot.layer?.cornerRadius = 6
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 12).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 12).isActive = true
            stack.addArrangedSubview(dot)
        }
        label.stringValue = title
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(label)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 28),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
        ])
        // 自定义视图默认不是辅助功能元素，要显式声明，VoiceOver 才能读到并操作页签。
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // 名称已经在页签自己身上，里面的图标和文字不再单独读。
    override func accessibilityChildren() -> [Any]? { [] }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // 卡片拖到页签上方时用强调色提示“松手即固定到这里”。
            let fill: NSColor = isDropTarget ? .controlAccentColor.withAlphaComponent(0.45) : (isSelected ? .labelColor.withAlphaComponent(0.12) : .clear)
            layer?.backgroundColor = fill.cgColor
        }
        label.textColor = .labelColor
        icon.contentTintColor = .labelColor
    }

    override func mouseDown(with event: NSEvent) {
        // 双击 Pinboard 页签直接改名（用户真机提出）；第一下照常切换页签。
        if event.clickCount == 2, let onDoubleClick { onDoubleClick() } else { onClick?() }
    }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    /// 这次拖动能不能放到页签上：面板当前的拖拽会话、没被 Esc 取消（审查 08）。进入和松手时用同一个判断。
    var acceptsDrop: ((any NSDraggingInfo) -> Bool)?

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard onDropClips != nil, acceptsDrop?(sender) ?? false else { return [] }
        isDropTarget = true
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { isDropTarget = false }
    override func draggingEnded(_ sender: any NSDraggingInfo) { isDropTarget = false }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isDropTarget = false
        let ids = ClipDrag.ids(from: sender.draggingPasteboard)
        guard !ids.isEmpty, let onDropClips, acceptsDrop?(sender) ?? false else { return false }
        onDropClips(ids)
        return true
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// 面板顶部的工具栏：搜索、列表页签、新建 Pinboard、更多菜单。布局数值见 PanelMetrics。
@MainActor
final class ToolbarView: NSView {
    var onSelectScope: ((ClipQuery.Scope) -> Void)?
    var onSearchButton: (() -> Void)?
    var onCreatePinboard: ((String) -> Void)?
    var onRenamePinboard: ((Pinboard, String) -> Void)?
    /// Pinboard 页签的右键菜单。
    var pinboardMenu: ((Pinboard) -> NSMenu?)?
    var onMore: ((NSView) -> Void)?
    /// 卡片被拖到某个 Pinboard 页签上。
    var onDropClips: (([Int64], Pinboard) -> Void)?
    /// 交给每个页签的落点判断。
    var acceptsDrop: ((any NSDraggingInfo) -> Bool)?
    /// 新建名称的编辑结束（提交或取消）后调用，让调用方把焦点交还给卡片区。
    var onEndEditing: (() -> Void)?

    let searchBar: SearchBar
    private let searchButton = ToolbarView.iconButton("magnifyingglass", label: String(localized: "搜索"))
    private let plusButton = ToolbarView.iconButton("plus", label: String(localized: "创建 Pinboard"))
    private let moreButton = ToolbarView.iconButton("ellipsis", label: String(localized: "更多"))
    private let tabs = NSStackView()
    /// 页签多到放不下时在这里横向滚动（L50）。
    private let tabsScroll = TabsScrollView()
    private let center = NSStackView()
    private var nameField: NSTextField?
    /// 正在重命名的 Pinboard；为空表示输入框是在新建。
    private var renamingBoard: Pinboard?

    private var pinboards: [Pinboard] = []
    private var scope: ClipQuery.Scope = .history
    /// 当前页签和各自对应的范围。Pinboard 没变时只改选中和折叠状态，不重建控件：
    /// 每次面板显示都重建的话，新控件进窗口时 AppKit 留下的依赖记录会越积越多（L46）。
    private var tabScopes: [(chip: TabChip, scope: ClipQuery.Scope)] = []

    var isSearching = false {
        didSet {
            guard isSearching != oldValue else { return }
            searchButton.isHidden = isSearching
            searchBar.isHidden = !isSearching
            plusButton.isHidden = isSearching
            refreshTabs()
        }
    }

    init(searchBar: SearchBar) {
        self.searchBar = searchBar
        super.init(frame: .zero)
        let m = PanelMetrics.self

        tabs.orientation = .horizontal
        tabs.spacing = 4
        center.orientation = .horizontal
        center.spacing = 8
        center.alignment = .centerY
        center.translatesAutoresizingMaskIntoConstraints = false
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.isHidden = true

        // 页签少时滚动视图和整排页签一样宽，整体仍居中；放不下时它被压窄，页签可以横向滚动。
        tabsScroll.drawsBackground = false
        tabsScroll.hasHorizontalScroller = false
        tabsScroll.hasVerticalScroller = false
        tabsScroll.verticalScrollElasticity = .none
        tabsScroll.documentView = tabs
        tabsScroll.translatesAutoresizingMaskIntoConstraints = false
        tabsScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        let fullWidth = tabsScroll.widthAnchor.constraint(equalTo: tabs.widthAnchor)
        // 低于 500（windowSizeStayPut）才不会把面板窗口撑大；高于 250 才不会被贴合压没。
        fullWidth.priority = .init(490)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: tabsScroll.contentView.leadingAnchor),
            tabs.topAnchor.constraint(equalTo: tabsScroll.contentView.topAnchor),
            tabsScroll.heightAnchor.constraint(equalTo: tabs.heightAnchor),
            fullWidth,
        ])

        for view in [searchButton, searchBar, tabsScroll, plusButton] as [NSView] { center.addArrangedSubview(view) }
        addSubview(center)
        addSubview(moreButton)

        searchButton.target = self
        searchButton.action = #selector(searchTapped)
        plusButton.target = self
        plusButton.action = #selector(beginCreatingPinboard)
        moreButton.target = self
        moreButton.action = #selector(moreTapped)

        NSLayoutConstraint.activate([
            center.centerXAnchor.constraint(equalTo: centerXAnchor),
            center.centerYAnchor.constraint(equalTo: centerYAnchor),
            center.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 60),
            center.trailingAnchor.constraint(lessThanOrEqualTo: moreButton.leadingAnchor, constant: -16),
            searchBar.widthAnchor.constraint(equalToConstant: m.searchFieldWidth),
            moreButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            // “更多”按钮右缘距窗口右边 23，窗口到玻璃面板还有 outerMargin。
            moreButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(23 - m.outerMargin)),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(pinboards: [Pinboard], scope: ClipQuery.Scope) {
        let changed = pinboards != self.pinboards
        self.pinboards = pinboards
        self.scope = scope
        changed ? rebuildTabs() : refreshTabs()
    }

    /// 页签控件不变，只更新选中和折叠状态；正在输入名称时照旧重建，输入框的位置要跟着排。
    private func refreshTabs() {
        guard nameField == nil, !tabScopes.isEmpty else { return rebuildTabs() }
        for (chip, tabScope) in tabScopes {
            chip.isSelected = tabScope == scope
            chip.isCollapsed = isSearching
        }
        revealSelectedTab()
    }

    /// 选中的页签在滚出可见范围时滚回来。
    private func revealSelectedTab() {
        guard let chip = tabScopes.first(where: { $0.scope == scope })?.chip else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutSubtreeIfNeeded()
            let frame = chip.convert(chip.bounds, to: self.tabs)
            self.tabs.scrollToVisible(frame)
        }
    }

    private func rebuildTabs() {
        let editing = nameField
        tabs.arrangedSubviews.filter { $0 !== editing }.forEach { $0.removeFromSuperview() }
        tabScopes = []

        let history = TabChip(title: String(localized: "剪贴板"), symbol: "clock.arrow.circlepath")
        history.isSelected = scope == .history
        history.isCollapsed = isSearching
        history.onClick = { [weak self] in self?.onSelectScope?(.history) }
        tabs.insertArrangedSubview(history, at: 0)
        tabScopes.append((history, .history))

        var index = 1
        for board in pinboards {
            // 正在重命名的那个页签由输入框顶替。
            if board.id == renamingBoard?.id, let editing {
                tabs.removeArrangedSubview(editing)
                tabs.insertArrangedSubview(editing, at: index)
                index += 1
                continue
            }
            let chip = TabChip(title: board.name, dotColor: NSColor(hex: board.colorHex) ?? .systemYellow)
            chip.isSelected = scope == .pinboard(board.id)
            chip.isCollapsed = isSearching
            chip.onClick = { [weak self] in self?.onSelectScope?(.pinboard(board.id)) }
            chip.menuProvider = { [weak self] in self?.pinboardMenu?(board) }
            chip.onDoubleClick = { [weak self] in self?.beginRenaming(board) }
            chip.onDropClips = { [weak self] in self?.onDropClips?($0, board) }
            chip.acceptsDrop = { [weak self] in self?.acceptsDrop?($0) ?? false }
            tabs.insertArrangedSubview(chip, at: index)
            tabScopes.append((chip, .pinboard(board.id)))
            index += 1
        }
        revealSelectedTab()
    }

    func beginRenaming(_ board: Pinboard) {
        guard nameField == nil, !isSearching else { return }
        renamingBoard = board
        showNameField(text: board.name)
        rebuildTabs()
        window?.makeFirstResponder(nameField)
    }

    // MARK: 新建 Pinboard（工具栏内联输入名称）

    @objc func beginCreatingPinboard() {
        guard nameField == nil, !isSearching else { return }
        showNameField(text: "")
        window?.makeFirstResponder(nameField)
    }

    private func showNameField(text: String) {
        let field = NSTextField(string: text)
        field.placeholderString = String(localized: "未命名")
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 120).isActive = true
        tabs.addArrangedSubview(field)
        nameField = field
    }

    private func endCreatingPinboard(commit: Bool) {
        guard let field = nameField else { return }
        nameField = nil
        let board = renamingBoard
        renamingBoard = nil
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        if let board {
            if commit, !name.isEmpty, name != board.name { onRenamePinboard?(board, name) } else { rebuildTabs() }
        } else if commit {
            onCreatePinboard?(name.isEmpty ? String(localized: "未命名") : name)
        }
        onEndEditing?()
    }

    #if DEBUG
    /// 页签区的可见宽度、全部页签的宽度，以及选中的页签是否完整可见。
    var debugTabsLayout: (visible: CGFloat, content: CGFloat, selectedVisible: Bool) {
        layoutSubtreeIfNeeded()
        let visibleRect = tabsScroll.contentView.documentVisibleRect
        let selected = tabScopes.first { $0.scope == scope }?.chip
        let selectedFrame = selected.map { $0.convert($0.bounds, to: tabs) } ?? .zero
        return (tabsScroll.frame.width, tabs.frame.width, visibleRect.insetBy(dx: -1, dy: -1).contains(selectedFrame))
    }
    var debugMoreButtonFrame: NSRect { moreButton.frame }
    var debugCenterFrame: NSRect { center.frame }
    #endif

    @objc private func searchTapped() { onSearchButton?() }
    @objc private func moreTapped() { onMore?(moreButton) }

    private static func iconButton(_ symbol: String, label: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.isBordered = false
        button.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        button.contentTintColor = .labelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: PanelMetrics.toolbarButtonSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: PanelMetrics.toolbarButtonSize).isActive = true
        return button
    }
}

extension ToolbarView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === nameField else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): endCreatingPinboard(commit: true); return true
        case #selector(NSResponder.cancelOperation(_:)): endCreatingPinboard(commit: false); return true
        default: return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // 点到别处失去焦点时放弃新建。
        if notification.object as AnyObject? === nameField { endCreatingPinboard(commit: false) }
    }
}

/// 页签的滚动视图：只横向滚动；鼠标滚轮的竖向滚动也换成横向。
private final class TabsScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaX == 0, event.scrollingDeltaY != 0, let documentView {
            let clip = contentView
            let maxX = max(0, documentView.frame.width - clip.bounds.width)
            let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
            clip.scroll(to: NSPoint(x: min(max(clip.bounds.origin.x - step, 0), maxX), y: clip.bounds.origin.y))
            reflectScrolledClipView(clip)
            return
        }
        super.scrollWheel(with: event)
    }
}

