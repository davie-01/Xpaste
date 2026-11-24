import AppKit
import ClipboardKit
import PasteCore

/// 日期筛选的档位，与原版筛选浮层一致：今天、昨天、本周、上周、过去 30 天。
enum DateFilter: String, CaseIterable {
    case today, yesterday, thisWeek, lastWeek, last30Days

    var title: String {
        switch self {
        case .today: String(localized: "今天")
        case .yesterday: String(localized: "昨天")
        case .thisWeek: String(localized: "本周")
        case .lastWeek: String(localized: "上周")
        case .last30Days: String(localized: "过去 30 天")
        }
    }

    /// 一周从哪天开始跟随用户的日历设置。
    func range(now: Date, calendar: Calendar = .current) -> (since: Date, until: Date?) {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
        switch self {
        case .today: return (startOfToday, nil)
        case .yesterday: return (calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday, startOfToday)
        case .thisWeek: return (startOfWeek, nil)
        case .lastWeek: return (calendar.date(byAdding: .day, value: -7, to: startOfWeek) ?? startOfWeek, startOfWeek)
        case .last30Days: return (calendar.date(byAdding: .day, value: -30, to: now) ?? now, nil)
        }
    }
}

/// 当前生效的结构化筛选条件。与搜索词是“且”的关系。
struct FilterState: Equatable {
    var kinds: Set<ClipKind> = []
    var bundleIDs: Set<String> = []
    var pinboardIDs: Set<String> = []
    var date: DateFilter?

    var isEmpty: Bool { kinds.isEmpty && bundleIDs.isEmpty && pinboardIDs.isEmpty && date == nil }

    func apply(to query: inout ClipQuery, now: Date = Date()) {
        query.kinds = kinds
        query.bundleIDs = bundleIDs
        query.pinboardIDs = pinboardIDs
        if let range = date?.range(now: now) {
            query.since = range.since
            query.until = range.until
        }
    }
}

extension ClipKind {
    /// 筛选浮层里类型的顺序，与原版一致。
    static let filterable: [ClipKind] = [.unknown, .image, .color, .file, .link, .text]

    var displayName: String {
        switch self {
        case .text: String(localized: "文本")
        case .link: String(localized: "链接")
        case .image: String(localized: "图片")
        case .color: String(localized: "颜色")
        case .file: String(localized: "文件")
        case .unknown: String(localized: "未知")
        }
    }

    var symbolName: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .color: "paintpalette"
        case .file: "doc"
        case .unknown: "questionmark.square"
        }
    }
}

/// 搜索框里的一个筛选标记，以及筛选浮层里的一个可选项。
struct FilterToken: Equatable {
    enum Kind: Equatable {
        case kind(ClipKind)
        case app(String)
        case pinboard(String)
        case date(DateFilter)
    }

    let kind: Kind
    let title: String
    /// 和浮层里对应选项相同的图标；搜索栏里的标记也带着它，和原版一样（L47）。
    var image: NSImage?

    static func == (lhs: FilterToken, rhs: FilterToken) -> Bool { lhs.kind == rhs.kind && lhs.title == rhs.title }
}

// MARK: - 搜索栏

/// 胶囊形搜索栏：放大镜、筛选标记、输入框、清除按钮、筛选按钮。
@MainActor
final class SearchBar: NSView {
    let textField = NSTextField()
    var onClear: (() -> Void)?
    var onFilterButton: (() -> Void)?

    private let tokenStack = NSStackView()
    /// 输入框已空时第一次退格选中最后一个标记（高亮），再按一次才删掉（原版如此）。打字、换条件都会取消选中。
    var isLastTokenSelected = false { didSet { if isLastTokenSelected != oldValue { updateTokenColors() } } }
    private let clearButton = SearchBar.button("xmark.circle.fill", label: String(localized: "清除"))
    private let filterButton = SearchBar.button("line.3.horizontal.decrease", label: String(localized: "筛选"))
    /// 筛选浮层的箭头指向这个按钮。
    var filterAnchor: NSView { filterButton }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor

        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 13)
        textField.placeholderString = String(localized: "搜索")
        textField.setAccessibilityLabel(String(localized: "搜索"))
        // 放大镜只是装饰，名称在输入框上。
        icon.setAccessibilityElement(false)
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.usesSingleLineMode = true
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        tokenStack.orientation = .horizontal
        tokenStack.spacing = 4
        clearButton.target = self
        clearButton.action = #selector(clearTapped)
        filterButton.target = self
        filterButton.action = #selector(filterTapped)

        let stack = NSStackView(views: [icon, tokenStack, textField, clearButton, filterButton])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            // 原版搜索框比页签高，32（对原版截图量过）。
            heightAnchor.constraint(equalToConstant: 32),
        ])
        setTokens([])
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTokens(_ tokens: [FilterToken]) {
        tokenStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for token in tokens {
            let label = NSTextField(labelWithString: token.title)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.lineBreakMode = .byTruncatingTail
            let icon = NSImageView(image: token.image ?? NSImage())
            icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.isHidden = token.image == nil
            icon.setAccessibilityElement(false)
            let row = NSStackView(views: [icon, label])
            row.spacing = 4
            row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
            let chip = NSView()
            chip.wantsLayer = true
            chip.layer?.cornerRadius = 5
            row.translatesAutoresizingMaskIntoConstraints = false
            chip.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: chip.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: chip.trailingAnchor),
                row.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 13),
                icon.heightAnchor.constraint(equalToConstant: 13),
                chip.heightAnchor.constraint(equalToConstant: 20),
                label.widthAnchor.constraint(lessThanOrEqualToConstant: 90),
            ])
            tokenStack.addArrangedSubview(chip)
        }
        tokenStack.isHidden = tokens.isEmpty
        isLastTokenSelected = false
        updateTokenColors()
        refreshClearButton(hasTokens: !tokens.isEmpty)
    }

    private func updateTokenColors() {
        let chips = tokenStack.arrangedSubviews
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (index, chip) in chips.enumerated() {
                let selected = isLastTokenSelected && index == chips.count - 1
                chip.layer?.backgroundColor = (selected ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.14)).cgColor
                for case let row as NSStackView in chip.subviews {
                    for view in row.arrangedSubviews {
                        (view as? NSTextField)?.textColor = selected ? .white : .labelColor
                        (view as? NSImageView)?.contentTintColor = selected ? .white : nil
                    }
                }
            }
        }
    }

    func refreshClearButton(hasTokens: Bool? = nil) {
        let tokens = hasTokens ?? !tokenStack.arrangedSubviews.isEmpty
        clearButton.isHidden = textField.stringValue.isEmpty && !tokens
    }

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
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
        updateTokenColors()
    }

    @objc private func clearTapped() { onClear?() }
    @objc private func filterTapped() { onFilterButton?() }

    private static func button(_ symbol: String, label: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: nil, action: nil)
        button.isBordered = false
        button.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        return button
    }
}

// MARK: - 筛选浮层

/// 浮层里的一个可点选项。
@MainActor
private final class FilterChip: NSView {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { updateColors() } }
    /// 键盘焦点所在的选项外面画一圈强调色描边（原版浮层里方向键移动的就是它）。
    var isFocused = false { didSet { updateColors() } }

    private let label = NSTextField(labelWithString: "")

    init(title: String, image: NSImage?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.cornerCurve = .continuous

        let imageView = NSImageView(image: image ?? NSImage())
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        imageView.contentTintColor = .labelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = title
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(imageView)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            widthAnchor.constraint(equalToConstant: FilterPanel.chipWidth),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.85) : NSColor.labelColor.withAlphaComponent(0.10)
            layer?.backgroundColor = color.cgColor
            layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
        layer?.borderWidth = isFocused ? 2 : 0
        label.textColor = isSelected ? .white : .labelColor
        setAccessibilityValue(isSelected)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    // 名称已经在选项自己身上，里面的图标和文字不再单独读。
    override func accessibilityChildren() -> [Any]? { [] }
}

/// 筛选浮层：悬在搜索栏上方的子窗口，下缘有箭头指向筛选按钮，材质和主面板一样是玻璃。
/// 不成为 key 窗口；打开期间按键由这里先处理：方向键在选项间移动焦点，回车选中焦点所在的项并关闭浮层，
/// 其余不带 ⌘ 的按键不起作用（不会打进搜索框），和原版一样（M5 第 6 步实测）。
/// 用鼠标点选一项也是选中后立即收起、回到搜索框（原版如此）；只有“更多”不收起。
@MainActor
final class FilterPanel {
    static let chipWidth: CGFloat = 140
    private static let columns = 3
    private static let spacing: CGFloat = 8
    private static let padding: CGFloat = 16
    private static let maxHeight: CGFloat = 330
    /// 应用一栏默认只列这么多，其余收在“更多”里。
    private static let collapsedAppCount = 8

    var onChange: ((FilterState) -> Void)?
    /// 选中了一项、浮层已收起，焦点该回到搜索框。
    var onPick: (() -> Void)?
    private(set) var state = FilterState()
    var isVisible: Bool { popover.isShown }

    /// 用系统的弹出框（原版也是）：玻璃材质、带圆滑箭头，都由系统画，和面板的玻璃一致。
    private let popover = NSPopover()
    private let controller = NSViewController()
    private let scrollView = NSScrollView()
    private var apps: [(bundleID: String, name: String?)] = []
    private var pinboards: [Pinboard] = []
    private var showsAllApps = false
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var window: NSWindow? { controller.viewIfLoaded?.window }
    /// 弹出框所在的窗口；面板据此判断键盘焦点是不是还在自己这边。
    var popoverWindow: NSWindow? { window }
    private var chips: [FilterChip] = []
    private var focusedIndex: Int? {
        didSet {
            if let oldValue, chips.indices.contains(oldValue) { chips[oldValue].isFocused = false }
            if let focusedIndex, chips.indices.contains(focusedIndex) {
                chips[focusedIndex].isFocused = true
                chips[focusedIndex].scrollToVisible(chips[focusedIndex].bounds)
            }
        }
    }
    init() {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.width, .height]
        controller.view = scrollView
        popover.contentViewController = controller
        // 收起由这里管：点到浮层外、选中一项、Esc。
        popover.behavior = .applicationDefined
        popover.animates = false
    }

    /// `anchor` 是筛选按钮，`bar` 是整个搜索框。弹出框从搜索框的上边框弹出，箭头横向对着筛选按钮（原版如此）。
    func show(above anchor: NSView, bar: NSView, in parent: NSWindow, state: FilterState, apps: [(bundleID: String, name: String?)], pinboards: [Pinboard]) {
        self.state = state
        self.apps = apps
        self.pinboards = pinboards
        showsAllApps = false
        rebuild()
        // 定位矩形取搜索框整个高度、筛选按钮中线处的一条竖线：弹出框贴着搜索框的上边，箭头在按钮正上方。
        let buttonX = anchor.convert(anchor.bounds, to: bar).midX
        popover.show(relativeTo: NSRect(x: buttonX - 0.5, y: 0, width: 1, height: bar.bounds.height), of: bar,
                     preferredEdge: bar.isFlipped ? .minY : .maxY)
        if let window { WindowSharing.apply(to: window) }
        // 弹出框会抢走键盘；按键由下面的监听处理，键盘还给面板（搜索框）。
        parent.makeKey()
        focusedIndex = nil
        installKeyMonitor()

        // 点到浮层以外的任何地方就收起。
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.window { self.close() }
            }
            return event
        }
    }

    func close() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        popover.close()
    }

    /// 外部（清除按钮、退格删标记）改了条件后同步过来。
    func sync(_ newState: FilterState) {
        state = newState
        if isVisible { rebuild() }
    }

    /// 点选或回车选中一项：切换条件，收起浮层，焦点回到搜索框。
    private func pick(_ token: FilterToken.Kind) {
        toggle(token)
        close()
        onPick?()
    }

    private func toggle(_ token: FilterToken.Kind) {
        switch token {
        case .kind(let kind): state.kinds.formSymmetricDifference([kind])
        case .app(let bundleID): state.bundleIDs.formSymmetricDifference([bundleID])
        case .pinboard(let id): state.pinboardIDs.formSymmetricDifference([id])
        case .date(let date): state.date = state.date == date ? nil : date
        }
        rebuild()
        onChange?(state)
    }

    private func rebuild() {
        let focused = focusedIndex
        focusedIndex = nil
        chips = []
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding)

        func section(_ title: String, _ chips: [FilterChip]) {
            guard !chips.isEmpty else { return }
            let header = NSTextField(labelWithString: title)
            header.font = .systemFont(ofSize: 12, weight: .semibold)
            header.textColor = .secondaryLabelColor
            content.addArrangedSubview(header)
            let rows = stride(from: 0, to: chips.count, by: Self.columns).map { Array(chips[$0..<min($0 + Self.columns, chips.count)]) as [NSView] }
            let grid = NSGridView(views: rows)
            grid.rowSpacing = Self.spacing
            grid.columnSpacing = Self.spacing
            content.addArrangedSubview(grid)
            content.setCustomSpacing(18, after: grid)
        }

        func chip(_ title: String, _ image: NSImage?, _ kind: FilterToken.Kind, selected: Bool) -> FilterChip {
            let chip = FilterChip(title: title, image: image)
            chip.isSelected = selected
            chip.onClick = { [weak self] in self?.pick(kind) }
            chips.append(chip)
            return chip
        }

        section(String(localized: "类型"), ClipKind.filterable.map {
            chip($0.displayName, Self.image(for: .kind($0)), .kind($0), selected: state.kinds.contains($0))
        })

        // 已选中的应用即使排在后面也要显示出来。
        let visibleApps = showsAllApps ? apps : apps.enumerated().filter { $0.offset < Self.collapsedAppCount || state.bundleIDs.contains($0.element.bundleID) }.map(\.element)
        var appChips = visibleApps.map { app in
            chip(app.name ?? app.bundleID, Self.image(for: .app(app.bundleID)), .app(app.bundleID),
                 selected: state.bundleIDs.contains(app.bundleID))
        }
        if !showsAllApps, visibleApps.count < apps.count {
            let more = FilterChip(title: String(localized: "更多"), image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil))
            more.onClick = { [weak self] in
                self?.showsAllApps = true
                self?.rebuild()
            }
            appChips.append(more)
        }
        section(String(localized: "应用"), appChips)

        section("Pinboard", pinboards.map { board in
            chip(board.name, Self.dot(board.colorHex), .pinboard(board.id), selected: state.pinboardIDs.contains(board.id))
        })

        section(String(localized: "日期"), DateFilter.allCases.map {
            chip($0.title, Self.image(for: .date($0)), .date($0), selected: state.date == $0)
        })

        let flipped = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            content.topAnchor.constraint(equalTo: flipped.topAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        // 宽度自己算：左对齐的纵向 NSStackView 算 fittingSize 时不带右侧内边距，浮层右边会少 16（V19 真机发现）。
        let width = Self.padding * 2 + CGFloat(Self.columns) * Self.chipWidth + CGFloat(Self.columns - 1) * Self.spacing
        let size = NSSize(width: width, height: content.fittingSize.height)
        flipped.frame = NSRect(origin: .zero, size: size)

        let keepOffset = scrollView.contentView.bounds.origin
        scrollView.documentView = flipped
        // 重建后保持浮层底边贴着搜索栏、滚动位置不跳。
        let height = min(size.height, Self.maxHeight)
        popover.contentSize = NSSize(width: size.width, height: height)
        if let focused, chips.indices.contains(focused) { focusedIndex = focused }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(keepOffset.y, max(0, size.height - height))))
    }

    // MARK: 键盘

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) == true }
            return handled ? nil : event
        }
    }

    /// 返回 true 表示按键已处理（吞掉）。带 ⌘ 的组合键照常往下走（⌘F 再按一次收起浮层）。
    private func handleKey(_ event: NSEvent) -> Bool {
        guard isVisible else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return false }
        switch Int(event.keyCode) {
        case 53: // Esc 交给面板：先收起浮层
            return false
        case 123: moveFocus { $0 - 1 }
        case 124: moveFocus { $0 + 1 }
        case 125: moveFocusVertically(down: true)
        case 126: moveFocusVertically(down: false)
        case 36, 76:
            if let index = focusedIndex, chips.indices.contains(index) {
                chips[index].onClick?()
            }
        default: break
        }
        return true
    }

    private func moveFocus(_ step: (Int) -> Int) {
        guard !chips.isEmpty else { return }
        guard let current = focusedIndex else { focusedIndex = 0; return }
        focusedIndex = min(max(step(current), 0), chips.count - 1)
    }

    /// 上下移到相邻一行里横向最近的那个选项（跨分区也一样）。
    private func moveFocusVertically(down: Bool) {
        guard !chips.isEmpty else { return }
        guard let current = focusedIndex else { focusedIndex = 0; return }
        let frames = chips.map { $0.convert($0.bounds, to: nil) }
        let here = frames[current]
        // 窗口坐标向上为正：往下是 y 更小的行。
        let candidates = frames.indices.filter { down ? frames[$0].maxY <= here.minY + 1 : frames[$0].minY >= here.maxY - 1 }
        guard let rowY = (down ? candidates.map { frames[$0].maxY }.max() : candidates.map { frames[$0].minY }.min()) else { return }
        let row = candidates.filter { abs((down ? frames[$0].maxY : frames[$0].minY) - rowY) < 1 }
        focusedIndex = row.min { abs(frames[$0].midX - here.midX) < abs(frames[$1].midX - here.midX) }
    }

    #if DEBUG
    /// 自检用：走一遍按键处理，返回是否被浮层吞掉。
    func debugPress(keyCode: UInt16, characters: String = "") -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { return false }
        return handleKey(event)
    }
    var debugFocusedIndex: Int? { focusedIndex }
    var debugWindow: NSWindow? { window }
    /// 用鼠标点第 index 个选项。
    func debugClick(index: Int) { if chips.indices.contains(index) { chips[index].onClick?() } }
    /// 选项整体离浮层左右两边的距离。
    var debugChipInsets: (left: CGFloat, right: CGFloat) {
        let frames = chips.map { $0.convert($0.bounds, to: scrollView) }
        guard let minX = frames.map(\.minX).min(), let maxX = frames.map(\.maxX).max() else { return (0, 0) }
        return (minX, scrollView.bounds.width - maxX)
    }
    #endif

    /// 当前条件对应的标记，按 类型、应用、Pinboard、日期 的顺序。
    func tokens() -> [FilterToken] {
        var tokens = ClipKind.filterable.filter(state.kinds.contains).map { FilterToken(kind: .kind($0), title: $0.displayName, image: Self.image(for: .kind($0))) }
        tokens += apps.filter { state.bundleIDs.contains($0.bundleID) }.map {
            FilterToken(kind: .app($0.bundleID), title: $0.name ?? $0.bundleID, image: Self.image(for: .app($0.bundleID)))
        }
        tokens += pinboards.filter { state.pinboardIDs.contains($0.id) }.map { FilterToken(kind: .pinboard($0.id), title: $0.name, image: Self.dot($0.colorHex)) }
        if let date = state.date { tokens.append(FilterToken(kind: .date(date), title: date.title, image: Self.image(for: .date(date)))) }
        return tokens
    }

    /// 选项和标记共用的图标。Pinboard 的色点要知道颜色，见 `dot(_:)`。
    private static func image(for kind: FilterToken.Kind) -> NSImage? {
        switch kind {
        case .kind(let kind): NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil)
        case .app(let bundleID): AppAppearanceCache.shared.appearance(for: bundleID).icon
        case .pinboard: nil
        case .date: NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)
        }
    }

    private static func dot(_ hex: String) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            (NSColor(hex: hex) ?? .systemYellow).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }

    /// 退格删除最后一个标记。
    func removeLastToken() {
        guard let last = tokens().last else { return }
        toggle(last.kind)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
