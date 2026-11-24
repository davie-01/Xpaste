import AppKit
import ClipboardKit
import PasteCore

/// Stack：打开期间每次复制入队，之后每按一次 ⌘V 按顺序粘出最上面一项（Docs/08 第 5.7、9.7、9.18 节）。
/// 改版后（Docs/验收记录/Stack改版.md）还能从面板、别的应用、MCP 加入，拖动排序，双击插队，全部粘贴，删除和撤销。
///
/// 接管 ⌘V 用的是会话级的主动事件拦截，只需要辅助功能授权（见 Docs/验收记录/M3-Stack权限原型.md）。
/// 回调里同步把下一项写进剪贴板，再放行原来的按键，目标应用读到的就是这一项。
@MainActor
final class StackController: NSObject {
    struct Entry {
        /// 窗口里这一行的编号。同一条目可以排进来几次，所以不用条目 ID。
        let uid: Int
        let clip: ClipSummary
        /// 内容留在内存里：按键回调里最好不去读库，写剪贴板要尽快完成。
        /// 队列里的内容总量超过 `memoryBudget` 后，新进来的只记 ID，粘到它时再读库（审查 12）。
        let snapshot: ClipSnapshot?
        let bytes: Int
    }

    /// 撤销时放回去的一行和它原来的位置。
    private struct Removal {
        let entry: Entry
        let index: Int
    }

    /// 队列在内存里最多留这么多内容。
    static let memoryBudget = 64 * 1024 * 1024
    /// 一次从面板加入很多条时，只预先读这么多条的内容，其余粘到时再读库。
    static let preloadLimit = 50

    private let store: HistoryStore
    private let pasteboard: NSPasteboard
    private let preferences: AppPreferences
    /// 自己写剪贴板之后调用，避免被当成一次新的复制。
    private let acknowledge: (Int) -> Void
    /// 粘出一项后调用（这一项回到了历史最前）。
    var onPasted: (() -> Void)?
    /// 别的应用拖进来的内容：存进历史，返回存好的条目（被采集规则挡掉时返回 nil）。
    var recordDropped: ((ClipSnapshot) async -> ClipSummary?)?

    private var queue: StackQueue<Entry>
    /// 文件行加进来时就在后台打开一次各个文件（同面板粘贴前的检查，`FileAccess`）：
    /// 受保护文件夹里的文件这时由系统询问授权；没有授权的文件 URL 写进剪贴板会被系统悄悄去掉，粘出来是空的（用户真机）。
    private var fileAccess: [Int: FileAccess.Result] = [:]
    private var undoStack: [[Removal]] = []
    private var nextUID = 1
    private var panel: NSPanel?
    private let listView = StackListView()
    private let scrollView = NSScrollView()
    private let undoButton = StackButton()
    private let moreButton = StackButton()
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var pasteKeyCode: CGKeyCode = 9
    private var trustTimer: Timer?

    static let width: CGFloat = 280
    static let headerHeight: CGFloat = 40
    /// 内容超过这个高度后滚动。
    static let maxContentHeight: CGFloat = 480
    static let cornerRadius: CGFloat = 22

    var isOpen: Bool { panel != nil }

    /// 自检里关掉，免得测试期间真的拦截用户的 ⌘V、真的向前台应用发 ⌘V。
    private let interceptsPaste: Bool

    init(store: HistoryStore, pasteboard: NSPasteboard = .general, preferences: AppPreferences = .shared, interceptsPaste: Bool = true,
         acknowledge: @escaping (Int) -> Void) {
        self.store = store
        self.pasteboard = pasteboard
        self.preferences = preferences
        self.interceptsPaste = interceptsPaste
        self.acknowledge = acknowledge
        queue = StackQueue(isReversed: preferences.stackReversed)
    }

    // MARK: 开关

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        guard !isOpen else { return }
        queue.removeAll()
        undoStack.removeAll()
        let panel = StackPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.headerHeight + StackListView.minRowHeight),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Stack"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = buildContent()
        panel.delegate = self
        WindowSharing.apply(to: panel)
        self.panel = panel
        refresh()
        panel.setFrameTopLeftPoint(savedTopLeft(for: panel))
        panel.orderFrontRegardless()
        installTap()
        // 会话中途授权被撤销时拦截会失效，界面上要看得出来。
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.checkTrust() } }
        RunLoop.main.add(timer, forMode: .common)
        trustTimer = timer
    }

    func close() {
        guard let panel else { return }
        removeTap()
        trustTimer?.invalidate()
        trustTimer = nil
        queue.removeAll()
        undoStack.removeAll()
        fileAccess.removeAll()
        self.panel = nil
        panel.delegate = nil
        panel.orderOut(nil)
        panel.close()
    }

    // MARK: 加入

    /// 收集期间的每次复制都入队，相同内容也不合并。条目照常进历史，这里只是另记一份顺序。
    func collect(_ snapshot: ClipSnapshot, summary: ClipSummary) {
        guard isOpen else { return }
        let entry = makeEntry(summary, snapshot: snapshot)
        queue.collect(entry)
        checkFiles([entry])
        refresh()
    }

    /// 从面板（选中项，按面板顺序）或 MCP 加入；Stack 没开时先打开（S4、S13）。
    func add(_ clips: [ClipSummary]) {
        guard !clips.isEmpty else { return }
        if !isOpen { open() }
        let added = entries(for: clips)
        queue.collect(contentsOf: added)
        checkFiles(added)
        refresh()
    }

    func add(ids: [Int64]) {
        add((try? store.summaries(ids: ids)) ?? [])
    }

    private func entries(for clips: [ClipSummary]) -> [Entry] {
        clips.enumerated().map { index, clip in
            makeEntry(clip, snapshot: index < Self.preloadLimit ? try? store.snapshot(id: clip.id) : nil)
        }
    }

    private func makeEntry(_ clip: ClipSummary, snapshot: ClipSnapshot?) -> Entry {
        let held = queue.items.reduce(0) { $0 + $1.bytes }
        let keep = snapshot.map { held + $0.byteCount <= Self.memoryBudget } ?? false
        defer { nextUID += 1 }
        return Entry(uid: nextUID, clip: clip, snapshot: keep ? snapshot : nil, bytes: keep ? snapshot?.byteCount ?? 0 : 0)
    }

    // MARK: 文件

    private func checkFiles(_ entries: [Entry]) {
        for entry in entries where entry.clip.kind == .file {
            let urls = entry.snapshot?.fileURLs ?? entry.clip.filePaths.map { URL(fileURLWithPath: $0) }
            guard !urls.isEmpty else { continue }
            let uid = entry.uid
            Task { [weak self] in
                let result = await FileAccess.check(urls)
                self?.fileAccess[uid] = result
            }
        }
    }

    // MARK: 粘贴

    /// 把一行的内容写进剪贴板；“以纯文本粘贴”打开时只写文本（S10）。返回剪贴板的新计数，写不进去时返回 nil。
    /// 文件已经检查过、有用不了的：只交出能用的（同面板，审查 11）；一个都用不了就说明原因，返回 nil。
    private func write(_ entry: Entry) -> Int? {
        guard var snapshot = entry.snapshot ?? (try? store.snapshot(id: entry.clip.id)) else { return nil }
        if let access = fileAccess[entry.uid], !access.isUsable {
            guard let kept = snapshot.removingFiles(access.unusable) else {
                // 在按键回调里，弹框放到回调之后。
                DispatchQueue.main.async { FileAccess.presentFailure(access) }
                return nil
            }
            snapshot = kept
        }
        return PasteboardWriter.write(snapshot, to: pasteboard, plainTextOnly: preferences.stackPastePlainText)
    }

    /// 粘过的条目回到历史最前。时间在调用处当场取：写库在后台，几次连着粘时后台任务的先后不固定（L146）。
    private func touch(_ entries: [Entry], at pastedAt: Date) {
        let store = store
        let ids = entries.map(\.clip.id)
        Task.detached(priority: .utility) {
            // 一次粘出多项时按 Stack 顺序依次往后排，最后一项在历史最前。
            for (offset, id) in ids.enumerated() { try? store.touch(id: id, now: pastedAt.addingTimeInterval(Double(offset) / 1000)) }
            await MainActor.run { [weak self] in self?.onPasted?() }
        }
    }

    /// 用户按下了 ⌘V。返回 true 表示把这次按键吞掉。
    fileprivate func handlePaste(isRepeat: Bool) -> Bool {
        guard isOpen, !queue.isEmpty else { return false }
        // 长按产生的重复按键吞掉：一次按下只推进一项，也不让目标应用把同一项粘很多遍。
        if isRepeat { return true }
        guard let entry = queue.next else { return false }
        // 写不进剪贴板时不推进队列、吞掉这次 ⌘V：放行的话会粘出剪贴板里原来的内容（审查 01）。
        guard let changeCount = write(entry) else {
            NSSound.beep()
            return true
        }
        _ = queue.takeNext()
        // ⌘V 逐项粘出的也能撤销，放回最上面（原版视频 00:19：按过一次 ⌘V 标题栏就出现撤销）。
        undoStack.append([Removal(entry: entry, index: 0)])
        acknowledge(changeCount)
        // 事件回调里只做保证这次 ⌘V 顺序所需的最少步骤（写剪贴板、推进队列），写库和刷新都放到回调之后（审查 05）。
        let pastedAt = Date()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.touch([entry], at: pastedAt)
            self.refresh()
            // 粘完最后一项就收起窗口（原版实测）。
            if self.queue.isEmpty { self.close() }
        }
        return false
    }

    /// 双击某一行：不按顺序，先把它粘出去（S8）。这一行离开 Stack，可以撤销。
    func pasteOutOfTurn(uid: Int) {
        guard let index = queue.items.firstIndex(where: { $0.uid == uid }) else { return }
        let entry = queue.items[index]
        guard let changeCount = write(entry) else { NSSound.beep(); return }
        acknowledge(changeCount)
        queue.remove(at: index)
        undoStack.append([Removal(entry: entry, index: index)])
        touch([entry], at: Date())
        sendPaste(changeCount: changeCount)
        finishRemoval()
    }

    /// 全部粘贴（S9）：所有文本项按 Stack 顺序一次粘出，每项一行；图片和文件留在 Stack 里。可以撤销。
    /// 返回是否粘了东西（没有文本项时返回 false）。
    @discardableResult
    func pasteAll() -> Bool {
        let texts = queue.items.enumerated().filter { [.text, .link, .color].contains($0.element.clip.kind) }
        let snapshots = texts.compactMap { $0.element.snapshot ?? (try? store.snapshot(id: $0.element.clip.id)) }
        guard !texts.isEmpty, snapshots.count == texts.count, let composed = MultiSelection.compose(snapshots, trailingNewline: false),
              let changeCount = PasteboardWriter.write(composed, to: pasteboard, plainTextOnly: preferences.stackPastePlainText) else {
            NSSound.beep()
            return false
        }
        acknowledge(changeCount)
        for (index, _) in texts.reversed() { queue.remove(at: index) }
        undoStack.append(texts.map { Removal(entry: $0.element, index: $0.offset) })
        touch(texts.map(\.element), at: Date())
        sendPaste(changeCount: changeCount)
        finishRemoval()
        return true
    }

    /// 向前台应用发 ⌘V。Stack 窗口不会成为前台，点它之后前台还是用户原来的应用。
    /// 等触发的修饰键（⌃⌥⌘V）松开再发；没有授权时只留在剪贴板里。
    private func sendPaste(changeCount: Int) {
        guard interceptsPaste, PastePerformer.isTrusted else { return }
        let pasteboard = pasteboard
        Task {
            _ = await PastePerformer.postPasteWhenModifiersReleased(timeout: .seconds(2)) { pasteboard.changeCount == changeCount }
        }
    }

    /// 插队粘贴、全部粘贴之后：粘空了就关掉（和 ⌘V 粘完最后一项一样），否则刷新。
    private func finishRemoval() {
        if queue.isEmpty { close() } else { refresh() }
    }

    // MARK: 整理

    /// 点 × 删除一行（S11）。删空了也不关窗口，留着撤销。
    func remove(uid: Int) {
        guard let index = queue.items.firstIndex(where: { $0.uid == uid }) else { return }
        undoStack.append([Removal(entry: queue.remove(at: index), index: index)])
        refresh()
    }

    /// 一行被拖到别的应用（S12）：它离开 Stack，可以撤销。
    private func draggedOut(uid: Int) {
        guard let index = queue.items.firstIndex(where: { $0.uid == uid }) else { return }
        let entry = queue.remove(at: index)
        undoStack.append([Removal(entry: entry, index: index)])
        touch([entry], at: Date())
        refresh()
    }

    /// 拖动排序（S6）：`destination` 是挪完之后的位置。
    func move(uid: Int, to destination: Int) {
        guard let index = queue.items.firstIndex(where: { $0.uid == uid }) else { return }
        queue.move(from: index, to: destination)
        refresh()
    }

    /// 把最近一次移走的行放回原来的位置。
    func undo() {
        guard let removals = undoStack.popLast() else { return }
        for removal in removals.sorted(by: { $0.index < $1.index }) {
            queue.insert(removal.entry, at: removal.index)
        }
        refresh()
    }

    var canUndo: Bool { !undoStack.isEmpty }

    /// 反转顺序（S7）：整列翻过来，之后新复制的接到另一头。
    func reverseOrder() {
        queue.reverse()
        preferences.stackReversed = queue.isReversed
        refresh()
    }

    func togglePlainText() {
        preferences.stackPastePlainText.toggle()
    }

    /// 面板卡片拖进来，放到 `index`。
    private func insert(ids: [Int64], at index: Int) {
        let clips = (try? store.summaries(ids: ids)) ?? []
        let added = entries(for: clips)
        for (offset, entry) in added.enumerated() { queue.insert(entry, at: index + offset) }
        checkFiles(added)
        refresh()
    }

    /// 别的应用拖进来：按复制的规则读出内容，存进历史后放到 `index`（S5）。
    private func insertExternal(from dragging: NSPasteboard, at index: Int) -> Bool {
        let source = NSWorkspace.shared.frontmostApplication.map { ClipSource(bundleID: $0.bundleIdentifier, name: $0.localizedName) }
            ?? ClipSource(bundleID: nil, name: nil)
        guard case .snapshot(let snapshot) = PasteboardReader.read(from: dragging, policy: preferences.capturePolicy, source: source),
              let recordDropped else { return false }
        Task { [weak self] in
            guard let summary = await recordDropped(snapshot), let self, self.isOpen else { return }
            let entry = self.makeEntry(summary, snapshot: snapshot)
            self.queue.insert(entry, at: index)
            self.checkFiles([entry])
            self.refresh()
        }
        return true
    }

    // MARK: 接管 ⌘V

    private func installTap() {
        guard interceptsPaste, eventTap == nil, PastePerformer.isTrusted else { refresh(); return }
        pasteKeyCode = PastePerformer.keyCodeForCommandV()
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                    callback: { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            // 事件源挂在主运行循环上，回调在主线程执行。
            let swallow = MainActor.assumeIsolated {
                Unmanaged<StackController>.fromOpaque(userInfo).takeUnretainedValue().handleTap(type: type, event: event)
            }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { refresh(); return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        tapSource = source
        refresh()
    }

    private func removeTap() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        eventTap = nil
        tapSource = nil
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // 回调太慢或系统临时停用时，拦截会被关掉，重新打开。
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return false
        }
        guard type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == Int64(pasteKeyCode),
              event.getIntegerValueField(.eventSourceUserData) != PastePerformer.ownEventTag else { return false }
        let flags = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        // 单独的 ⌘V 逐项粘贴；⌃⌥⌘V 全部粘贴（S9），没有文本项时放行。其余组合是别的功能。本应用自己发出的 ⌘V 不算。
        if flags == .maskCommand { return handlePaste(isRepeat: isRepeat) }
        if flags == [.maskCommand, .maskAlternate, .maskControl], isOpen {
            if isRepeat { return true }
            guard queue.items.contains(where: { [.text, .link, .color].contains($0.clip.kind) }) else { return false }
            pasteAll()
            return true
        }
        return false
    }

    private func checkTrust() {
        guard isOpen else { return }
        if PastePerformer.isTrusted {
            if eventTap == nil { installTap() }
        } else if eventTap != nil {
            removeTap()
            refresh()
        }
    }

    // MARK: 窗口

    private func buildContent() -> NSView {
        // 玻璃材质，和面板一致（S1）。
        let glass = NSGlassEffectView()
        glass.cornerRadius = Self.cornerRadius
        let content = NSView()
        glass.contentView = content

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown

        let title = NSTextField(labelWithString: "Stack")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor

        func headerButton(_ button: StackButton, symbol: String, label: String, action: Selector) {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            button.action = action
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
        headerButton(undoButton, symbol: "arrow.uturn.backward", label: String(localized: "撤销"), action: #selector(undoClicked))
        headerButton(moreButton, symbol: "ellipsis", label: String(localized: "更多"), action: #selector(moreClicked))
        let close = StackButton()
        headerButton(close, symbol: "xmark", label: String(localized: "关闭"), action: #selector(closeClicked))

        let buttons = NSStackView(views: [undoButton, moreButton, close])
        buttons.spacing = 6
        for button in [undoButton, moreButton, close] {
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = listView
        listView.onDoubleClick = { [weak self] in self?.pasteOutOfTurn(uid: $0) }
        listView.onRemove = { [weak self] in self?.remove(uid: $0) }
        listView.onMove = { [weak self] in self?.move(uid: $0, to: $1) }
        listView.onDropIDs = { [weak self] in self?.insert(ids: $0, at: $1) }
        listView.onDropExternal = { [weak self] in self?.insertExternal(from: $0, at: $1) ?? false }
        listView.onDraggedOut = { [weak self] in self?.draggedOut(uid: $0) }
        listView.dragItem = { [weak self] uid in
            guard let self, let entry = self.queue.items.first(where: { $0.uid == uid }) else { return nil }
            return ClipDragProvider.pasteboardItem(store: self.store, content: .single(entry.clip), idsField: String(entry.clip.id))
        }

        for view in [icon, title, buttons, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: content.topAnchor, constant: Self.headerHeight / 2),
            icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            buttons.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.headerHeight),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        return glass
    }

    /// 按队列重画各行，并让窗口高度跟着内容变，上缘位置不动。
    private func refresh() {
        guard let panel else { return }
        // 没有授权时 ⌘V 不会按顺序粘：在最上面说明，点这一行打开系统设置里的那一页（L113，用户真机：原来的说法看不懂要去哪里）。
        let untrusted = eventTap == nil && !PastePerformer.isTrusted
        let notice = untrusted ? StackListView.Notice(text: String(localized: "直接粘贴权限已关闭，⌘V 暂不能按顺序粘贴。点这里打开设置"),
                                                      action: { SystemSettings.openPrivacy("Privacy_Accessibility") }) : nil
        listView.update(rows: queue.displayed.map(Self.row(for:)), notice: notice, placeholder: String(localized: "复制的内容会依次排在这里"))
        undoButton.isHidden = undoStack.isEmpty

        let content = listView.contentHeight
        let visible = min(content, Self.maxContentHeight)
        listView.frame = NSRect(x: 0, y: 0, width: Self.width, height: max(content, visible))
        let height = Self.headerHeight + visible
        var frame = panel.frame
        frame.origin.y = frame.maxY - height
        frame.size = NSSize(width: Self.width, height: height)
        panel.setFrame(frame, display: true)
        // 下一次要粘的总是最上面一行，列表变化后回到顶部。
        listView.scroll(.zero)
    }

    /// 一行的文字和右侧图（S2）：文本带格式时按富文本显示；链接、图片、文件、颜色在右侧显示网站图标、缩略图或色块。
    static func row(for entry: Entry) -> StackListView.Row {
        let clip = entry.clip
        let font = StackListView.font
        func plain(_ text: String) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        }
        var text = plain(rowTitle(for: clip))
        var accessory = StackListView.Row.Accessory.none
        switch clip.kind {
        case .text, .unknown:
            if clip.title == nil, let data = clip.richPreview, let rich = NSAttributedString(rtf: data, documentAttributes: nil) {
                let trimmed = rich.attributedSubstring(from: NSRange(location: 0, length: min(rich.length, 300)))
                text = RichTextDisplay.prepare(trimmed, font: font)
            }
        case .link:
            if let picture = clip.linkImage == .none ? nil : ThumbnailCache.shared.image(for: clip) {
                accessory = clip.linkImage == .image ? .cover(picture) : .icon(picture)
            } else {
                accessory = .symbol("link")
            }
        case .image:
            accessory = ThumbnailCache.shared.image(for: clip).map { .cover($0) } ?? .symbol("photo")
        case .file:
            let paths = clip.filePaths
            if paths.count == 1, let thumbnail = ThumbnailCache.shared.image(for: clip) {
                accessory = .cover(thumbnail)
            } else if let first = paths.first {
                accessory = .icon(NSWorkspace.shared.icon(forFile: first))
            }
        case .color:
            accessory = .color(NSColor(hex: clip.previewText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .gray)
        }
        return StackListView.Row(uid: entry.uid, text: text, accessory: accessory,
                                 accessibilityLabel: "\(clip.kind.displayName)：\(rowTitle(for: clip))")
    }

    private static func rowTitle(for clip: ClipSummary) -> String {
        if let title = clip.title { return title }
        switch clip.kind {
        case .image: return ClipCardItem.typeTitle(for: clip)
        case .file: return clip.filePaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "、")
        case .link:
            let text = clip.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.replacingOccurrences(of: #"^https?://(www\.)?"#, with: "", options: .regularExpression)
        case .color:
            let text = clip.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
            return "#" + (text.hasPrefix("#") ? String(text.dropFirst()) : text).uppercased()
        case .text, .unknown:
            let text = clip.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? ClipCardItem.typeTitle(for: clip) : String(text.prefix(300))
        }
    }

    /// “…”菜单（S7、S9、S10）。
    private func moreMenu() -> NSMenu {
        let menu = NSMenu()
        let hasText = queue.items.contains { [.text, .link, .color].contains($0.clip.kind) }
        let pasteAll = ClosureMenuItem(String(localized: "全部粘贴")) { [weak self] in self?.pasteAll() }
            .shortcut("v", [.control, .option, .command])
        pasteAll.isEnabled = hasText
        menu.autoenablesItems = false
        menu.addItem(pasteAll)
        let reverse = ClosureMenuItem(String(localized: "反转顺序")) { [weak self] in self?.reverseOrder() }
        reverse.isEnabled = queue.count > 1
        menu.addItem(reverse)
        menu.addItem(.separator())
        let plain = ClosureMenuItem(String(localized: "以纯文本粘贴")) { [weak self] in self?.togglePlainText() }
        plain.state = preferences.stackPastePlainText ? .on : .off
        menu.addItem(plain)
        return menu
    }

    /// 窗口左上角的位置记在偏好里；记下的位置不在任何屏幕上时回到默认位置。
    private func savedTopLeft(for panel: NSPanel) -> NSPoint {
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let fallback = NSPoint(x: visible.minX + 40, y: visible.maxY - 40)
        guard let stored = preferences.stackWindowTopLeft else { return fallback }
        let parts = stored.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return fallback }
        let point = NSPoint(x: parts[0], y: parts[1])
        let probe = NSRect(x: point.x, y: point.y - Self.headerHeight, width: Self.width, height: Self.headerHeight)
        return NSScreen.screens.contains { $0.frame.intersects(probe) } ? point : fallback
    }

    @objc private func closeClicked() { close() }
    @objc private func undoClicked() { undo() }
    @objc private func moreClicked() {
        moreMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.height + 4), in: moreButton)
    }
}

extension StackController: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        preferences.stackWindowTopLeft = "\(panel.frame.minX),\(panel.frame.maxY)"
    }
}

/// 不抢键盘焦点的浮动小窗。
private final class StackPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

#if DEBUG || BENCH
extension StackController {
    var debugTitles: [String] { queue.displayed.map { $0.clip.title ?? $0.clip.previewText } }
    var debugUIDs: [Int] { queue.displayed.map(\.uid) }
    var debugWindowHeight: CGFloat? { panel?.frame.height }
    var debugIsReversed: Bool { queue.isReversed }
    var debugUndoVisible: Bool { !undoButton.isHidden }
    var debugRowTexts: [String] { listView.rows.map(\.text.string) }
    /// 各行右侧是不是铺满的缩略图。
    var debugRowHasCover: [Bool] { listView.rows.map { if case .cover = $0.accessory { true } else { false } } }
    var debugWindowNumber: Int? { panel?.windowNumber }
    var debugList: StackListView { listView }
    /// 第几行的文件检查结果；还没查完是 nil。
    func debugFileAccess(row index: Int) -> FileAccess.Result? { fileAccess[queue.displayed[index].uid] }
    /// 把窗口内容画成图（玻璃材质画不出来，只看排版）。
    func debugSnapshot(to url: URL, appearance: NSAppearance? = nil) {
        guard let view = panel?.contentView else { return }
        view.appearance = appearance
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        (appearance?.name == .darkAqua ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        NSRect(origin: .zero, size: view.bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        view.appearance = nil
    }
    func debugFlipDirection() { reverseOrder() }
    /// 走一遍“用户按了 ⌘V”的处理，返回按键是否被吞掉。
    func debugPressPaste(isRepeat: Bool = false) -> Bool { handlePaste(isRepeat: isRepeat) }
    func debugMenuTitles() -> [String] { moreMenu().items.map(\.title) }
}
#endif
