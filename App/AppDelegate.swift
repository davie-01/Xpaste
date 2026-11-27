import AppKit
import SwiftUI
import ClipboardKit
import PasteCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: HistoryStore!
    private let monitor = PasteboardMonitor()
    private let directPastePermission = DirectPastePermission()
    private var ocrIndexer: OCRIndexer?
    private var linkIndexer: LinkIndexer?
    private var mcp: MCPController?
    private var mcpSettings: MCPSettingsModel?
    private lazy var panelController = PanelController(store: store)

    /// 设置、引导、帮助窗口用到时才建，关掉就放（轻量化）。
    private lazy var settingsWindow = OnDemandWindow { [unowned self] in self.makeSettingsController() }
    private var settingsController: SettingsWindowController { settingsWindow.controller }

    private func makeSettingsController() -> SettingsWindowController {
        SettingsWindowController(onRetention: { [weak self] in try self?.changeRetention($0) }, onEraseHistory: { [weak self] in
        self?.eraseHistory()
    }, onPrivacyChange: { [weak self] in self?.applyPrivacySettings() }, onKeyboardChange: { [weak self] in try self?.shortcutRegistry.apply($0) },
       onRecording: { [weak self] in self?.setShortcutRecording($0) }, mcp: mcpSettings, onRecognizeAgain: { [weak self] in
        try self?.recognizeImagesAgain() ?? 0
    }, onHelp: { [weak self] in self?.helpController.present() })
    }

    private lazy var onboardingWindow = OnDemandWindow { [unowned self] in
        OnboardingWindowController(onRetention: { [weak self] in try self?.changeRetention($0) },
            onKeyboardChange: { [weak self] in try self?.shortcutRegistry.apply($0) }, onRecording: { [weak self] in self?.setShortcutRecording($0) })
    }
    private var onboardingController: OnboardingWindowController { onboardingWindow.controller }

    private var statusItem: NSStatusItem?
    private var statusIcon: StatusIcon?
    private lazy var shortcutRegistry = GlobalShortcutRegistry(activate: { [weak self] in self?.togglePanel() },
                                                               stack: { [weak self] in self?.stackShortcutPressed() })
    private var stack: StackController?
    private var retentionTimer: Timer?
    private var resumeTimer: Timer?
    private var pausedUntil: Date?
    /// 用户自己暂停了记录（菜单、⌘T、定时暂停）。
    private var userPaused = false
    /// 屏幕锁定或切到了别的用户（审查 10）。这期间也不记录，回来自动恢复，不显示暂停标记。
    private var sessionInactive = false
    /// 上一次采集的入库。入库在后台做，后一次等前一次写完，顺序与复制的顺序一致。
    private var lastCapture: Task<Void, Never>?

    /// 窗口状态用安全编码保存（系统要求；不声明时启动会在日志里警告）。各窗口的位置另由 frame autosave 记住。
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launch = Log.signposter.beginInterval("launch", id: Log.signposter.makeSignpostID())
        defer { Log.signposter.endInterval("launch", launch) }
        #if BENCH
        // 测量构建不走正常启动：不打开真实数据、不注册快捷键、不碰系统剪贴板。
        if Bench.shouldRun {
            Task { await Bench.run() }
            return
        }
        #endif
        #if DEBUG
        // 验收外观用：不切换系统外观也能看深色或浅色（XPASTE_APPEARANCE=light|dark）。
        switch ProcessInfo.processInfo.environment["XPASTE_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        if SelfTest.isRequested {
            Task { await SelfTest.run() }
            return
        }
        // 核对完全磁盘访问的检测：XPASTE_FDA_REPORT=<文件> 时把结果写进文件后退出。要用 open 启动，结果才是本应用自己的授权。
        if let report = ProcessInfo.processInfo.environment["XPASTE_FDA_REPORT"] {
            try? "fullDiskAccess=\(FullDiskAccess.isGranted) directPaste=\(DirectPastePermission.isTrusted)\n".write(toFile: report, atomically: true, encoding: .utf8)
            exit(0)
        }
        // 手工核对取链接信息：XPASTE_FETCH_URL=<网址> 时取一次、打印结果后退出。
        if let address = ProcessInfo.processInfo.environment["XPASTE_FETCH_URL"], let url = URL(string: address) {
            Task {
                do {
                    let metadata = try await LinkMetadataFetcher.fetch(url)
                    print("FETCH title=\(metadata.title ?? "nil") image=\(metadata.image?.count ?? 0) bytes kind=\(metadata.imageKind)")
                } catch {
                    print("FETCH failed: \(error)")
                }
                exit(0)
            }
            return
        }
        #endif
        do {
            store = try HistoryStore(directory: Self.dataDirectory)
            #if DEBUG
            if AppPreferences.testProfile != nil { try SelfTest.prepareSettingsVerification(store: store) }
            #endif
        } catch {
            // 数据库打不开时不带着空库继续运行，避免之后把旧数据覆盖掉。
            let detail = error is HistoryStore.NewerDatabaseError
                ? String(localized: "数据库已被更新版本的 XPaste 使用过，这个版本不会改动它。请改用更新的版本。\n\n数据目录：\(Self.dataDirectory.path)")
                : String(localized: "\(error.localizedDescription)\n\n数据目录：\(Self.dataDirectory.path)")
            NSAlert.showMessage(String(localized: "无法打开 XPaste 的数据库"), detail: detail, style: .critical)
            NSApp.terminate(nil)
            return
        }

        AppAppearanceCache.shared.onColorComputed = { [weak self] bundleID, hex in
            try? self?.store.setAppColor(bundleID: bundleID, hex: hex)
        }
        AppAppearanceCache.shared.onIconAvailable = { [weak self] bundleID, png in
            try? self?.store.setAppIconIfMissing(bundleID: bundleID, png: png)
        }
        AppAppearanceCache.shared.storedIcon = { [weak self] bundleID in (try? self?.store.appIcon(bundleID: bundleID)) ?? nil }

        // 图片文字识别在后台逐张进行；启动时先把上次没做完的补上。
        let indexer = OCRIndexer(store: store) { try await TextRecognition.recognize($0) }
        ocrIndexer = indexer
        Task { await indexer.kick() }

        // 链接的页面标题和配图同样在后台逐条补；“生成链接预览”关着时不发请求。
        let links = LinkIndexer(store: store, isEnabled: { AppPreferences.shared.generateLinkPreviews }, onChange: { [weak self] in
            Task { @MainActor in
                // 改过地址的链接会换配图，旧的缩略图不能再用。
                ThumbnailCache.shared.removeAll()
                self?.panelController.historyDidChange()
            }
        }) { try await LinkMetadataFetcher.fetch($0) }
        linkIndexer = links
        Task { await links.kick() }

        // 只有 HTML 的条目补写卡片缓存；启动时先把上次退出前没做完的补上。
        kickRichRefresh()

        let stack = StackController(store: store) { [weak self] in self?.monitor.acknowledge(changeCount: $0) }
        stack.onPasted = { [weak self] in
            self?.panelController.historyDidChange()
            SoundEffects.shared.play(.paste)
        }
        stack.recordDropped = { [weak self] snapshot in await self?.recordDropped(snapshot) }
        self.stack = stack
        panelController.onAddToStack = { [weak self] in self?.stack?.add($0) }
        panelController.isStackOpen = { [weak self] in self?.stack?.isOpen ?? false }

        monitor.policy = AppPreferences.shared.capturePolicy
        monitor.onCapture = { [weak self] in self?.capture($0) }
        // 没进历史的复制都留一行日志（L168）：被策略跳过、数据一直没准备好而放弃。只记原因，不记内容。
        // 自己写回的那种每次从面板粘贴都可能有，记成 debug（不落盘），其余记 notice，事后用 log show 能查到。
        monitor.onSkip = { reason in
            if reason == .ownWrite {
                Log.capture.debug("跳过一次复制：自己写回的内容")
            } else {
                Log.capture.notice("跳过一次复制：\(String(describing: reason), privacy: .public)")
            }
        }
        monitor.onGiveUp = { changeCount in
            Log.capture.notice("放弃一次复制：剪贴板计数 \(changeCount, privacy: .public) 变了，但重试后仍读不到可用的数据")
        }
        #if DEBUG
        if Self.usesRealClipboard { monitor.start() }
        #else
        monitor.start()
        #endif

        panelController.onPaste = { [weak self] clips, plainText, direct, target in
            self?.paste(clips, plainText: plainText, direct: direct, target: target)
        }

        // 编辑或新建出来的内容和复制来的一样，要补识别和链接信息。
        panelController.onContentEdited = { [weak self] clip in
            guard let self else { return }
            self.panelController.historyDidChange()
            if clip.kind == .link, let linkIndexer = self.linkIndexer { Task { await linkIndexer.kick() } }
            if clip.kind == .image, let ocrIndexer = self.ocrIndexer { Task { await ocrIndexer.kick() } }
        }

        panelController.onPause = { [weak self] in self?.pause(for: $0) }
        panelController.onResume = { [weak self] in self?.resume() }
        panelController.pauseStatus = { [weak self] in (self?.userPaused ?? false, self?.pausedUntil) }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleResume() }
        }
        observeSessionActivity()
        // 屏幕布局变了（审查 09）：主面板收起，下次按鼠标所在屏重新摆；其余已打开的窗口挪回能操作的位置。
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panelController.hide()
                // 主面板和提示 HUD 每次显示都会按当前屏幕重新摆，不在这里动。
                for window in NSApp.windows where window.isVisible && window !== self.panelController.window && !StatusHUD.shared.owns(window) {
                    WindowPlacement.keepOnScreen(window)
                }
            }
        }

        panelController.onSettings = { [weak self] in self?.showSettings() }
        // SwiftUI 的提示框、系统面板等不经本应用创建的窗口，成为 key 时补上共享标记。
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        setUpApplicationMenu()
        setUpStatusItem()
        registerHotKey()
        scheduleRetention()
        startMCP()
        Updates.shared.start()
        let showsOnboarding = shouldShowOnboarding
        if showsOnboarding { onboardingController.present() }
        #if DEBUG
        if AppPreferences.testProfile != nil, !showsOnboarding {
            let environment = ProcessInfo.processInfo.environment
            if environment["XPASTE_SIMULATE_UNTRUSTED"] == "1" || environment["XPASTE_SHOW_PANEL"] == "1" { panelController.show() }
            else { showSettings() }
            if let directory = environment["XPASTE_SNAPSHOT_DIR"] { Task { await writeSnapshots(to: URL(fileURLWithPath: directory)) } }
            if let directory = environment["XPASTE_GALLERY_DIR"] { Task { await writeGallery(to: URL(fileURLWithPath: directory)) } }
        }
        #endif
    }

    #if DEBUG
    /// 弹窗和带按钮页面的图库（XPASTE_GALLERY_DIR=<目录>，只在测试域里）：把每个弹窗、设置页、引导页、帮助、面板、编辑器、Stack
    /// 依次在屏幕上打开，用 screencapture 按窗口编号截图（不按坐标截，只拍 XPaste 自己的窗口），截完关掉，最后退出。
    /// 阻塞式的弹窗先排定时器再弹：定时器在弹窗显示时截图并中止等待，返回的是“中止”，不会执行任何按钮的操作。
    /// 能直接调用的走真实代码；写在私有方法里的照原样重建（同样的文案、按钮、回车和 Esc），文件名里标“重建”。
    private func writeGallery(to directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var index = 0
        func numbered(_ name: String) -> String {
            index += 1
            return String(format: "%02d-%@", index, name)
        }
        // 系统确认框的内容由系统另外绘制，按窗口截图是白的，改截它所在的屏幕区域（就是它自己的边框）；
        // 截图期间后面铺一层 XPaste 自己的纯色窗口，区域里不会拍到别的应用。
        @Sendable func shoot(_ window: NSWindow?, _ fileName: String, region: Bool = false) {
            guard let window, window.isVisible else { print("GALLERY 没有窗口：\(fileName)"); return }
            let file = directory.appendingPathComponent(fileName + ".png")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            if region, let primary = NSScreen.screens.first {
                let frame = window.frame.insetBy(dx: -24, dy: -24)
                let top = primary.frame.maxY - frame.maxY
                process.arguments = ["-x", "-R\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))", file.path]
            } else {
                process.arguments = ["-x", "-o", "-l\(window.windowNumber)", file.path]
            }
            try? process.run()
            process.waitUntilExit()
            print("GALLERY \(file.lastPathComponent)")
        }
        func capture(_ window: NSWindow?, _ name: String) {
            let fileName = numbered(name)
            if let only = ProcessInfo.processInfo.environment["XPASTE_GALLERY_ONLY"], !name.contains(only) { return }
            shoot(window, fileName)
        }
        let only = ProcessInfo.processInfo.environment["XPASTE_GALLERY_ONLY"]
        func captureModal(_ name: String, _ present: () async -> Void) async {
            let fileName = numbered(name)
            if let only, !name.contains(only) { return }
            let timer = Timer(timeInterval: 1.2, repeats: false) { _ in
                MainActor.assumeIsolated {
                    let window = NSApp.modalWindow
                    shoot(window, fileName, region: window is NSPanel && !(String(describing: type(of: window!)).contains("QuestionPanel")))
                    window?.orderOut(nil)
                    NSApp.abortModal()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            await present()
            try? await Task.sleep(for: .milliseconds(800))
        }
        func rebuilt(_ title: String, _ detail: String?, _ buttons: [String], defaultButton: Int, cancelButton: Int?, destructive: Int? = nil, warning: Bool = false) {
            let alert = NSAlert()
            if warning { alert.alertStyle = .warning }
            alert.messageText = title
            if let detail { alert.informativeText = detail }
            buttons.forEach { alert.addButton(withTitle: $0) }
            if let destructive { alert.buttons[destructive].hasDestructiveAction = true }
            WindowSharing.apply(to: alert.window)
            _ = alert.runModal(defaultButton: defaultButton, cancelButton: cancelButton)
        }
        func window(named className: String) -> NSWindow? {
            NSApp.windows.first { String(describing: type(of: $0)).contains(className) && $0.isVisible }
        }
        settingsController.close()
        let backdrop = NSWindow(contentRect: NSScreen.screens.first?.frame ?? .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.backgroundColor = NSColor.windowBackgroundColor
        backdrop.level = .floating
        backdrop.ignoresMouseEvents = true
        backdrop.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(500))

        // 一、确认框
        await captureModal("弹窗-删除所选4项") { _ = self.panelController.confirmBatchDelete(4, true) }
        await captureModal("弹窗-删除所选300项-无法撤销") { _ = self.panelController.confirmBatchDelete(300, false) }
        await captureModal("弹窗-删除Pinboard") { self.panelController.debugConfirmDeleteFirstPinboard() }
        await captureModal("弹窗-删除所有历史") {
            _ = SettingsActions.confirm(title: String(localized: "删除所有历史记录？"), detail: String(localized: "未固定的历史项目将永久删除。已固定的项目和 Pinboard 会保留，此操作无法撤销。"), action: String(localized: "删除"))
        }
        await captureModal("弹窗-缩短保留期限") {
            _ = SettingsActions.confirm(title: String(localized: "缩短历史保留期限？"), detail: String(localized: "超过新保留期限的历史将被清理。已固定的项目会保留，清理无法撤销。"),
                                       action: String(localized: "缩短"))
        }
        await captureModal("弹窗-恢复默认快捷键-重建") {
            rebuilt(String(localized: "恢复所有默认快捷键？"), String(localized: "四个快捷键和两种修饰键将恢复为默认设置。"), [String(localized: "取消"), String(localized: "重置")], defaultButton: 0, cancelButton: 0, destructive: 1)
        }
        await captureModal("弹窗-断开MCP连接-重建") {
            rebuilt(String(localized: "要断开“\("Claude Code")”的连接吗？"), String(localized: "断开后，\("Claude Code") 要重新连接才能使用 XPaste。"),
                    [String(localized: "取消"), String(localized: "断开连接")], defaultButton: 0, cancelButton: 0, destructive: 1)
        }
        await captureModal("弹窗-更改端口-重建") {
            rebuilt(String(localized: "更改端口？"), String(localized: "所有已连接的 AI 工具都将断开并移除，需要重新连接。"), [String(localized: "取消"), String(localized: "更改")], defaultButton: 0, cancelButton: 0)
        }
        await captureModal("弹窗-允许MCP连接") { _ = await MCPController.askApproval(clientName: "Claude Code") }
        let sample = URL(fileURLWithPath: "/Users/Shared/示例文件夹/报告.pdf")
        await captureModal("弹窗-无法粘贴文件-缺权限") { FileAccess.presentFailure(FileAccess.Result(denied: [sample])) }
        await captureModal("弹窗-启用直接粘贴") { _ = DirectPasteQuestion(appName: "备忘录").run() }

        // 二、只有“好”的提示框
        await captureModal("提示-文件已不存在") { FileAccess.presentFailure(FileAccess.Result(missing: [sample])) }
        await captureModal("提示-读取文件出错") { FileAccess.presentFailure(FileAccess.Result(unreadable: [sample])) }
        await captureModal("提示-无法打开数据库-重建") {
            rebuilt(String(localized: "无法打开 XPaste 的数据库"), String(localized: "数据库已被更新版本的 XPaste 使用过，这个版本不会改动它。请改用更新的版本。\n\n数据目录：\(Self.dataDirectory.path)"),
                    [String(localized: "好")], defaultButton: 0, cancelButton: 0)
        }
        await captureModal("提示-快捷键不可用-重建") {
            rebuilt(String(localized: "快捷键不可用"), "⇧⌘V 已被其他应用占用。", [String(localized: "好")], defaultButton: 0, cancelButton: 0)
        }
        await captureModal("提示-登录时打开失败-重建") {
            rebuilt(String(localized: "登录时打开"), "需要在“系统设置 › 通用 › 登录项”中允许 XPaste。", [String(localized: "好")], defaultButton: 0, cancelButton: 0)
        }
        await captureModal("提示-无法更改设置-SwiftUI提示框重建") {
            rebuilt(String(localized: "无法更改设置"), "写入设置时出错。", [String(localized: "好")], defaultButton: 0, cancelButton: 0)
        }

        backdrop.orderOut(nil)
        // 三、带按钮的页面
        for page in SettingsPage.allCases {
            settingsController.present(page: page)
            try? await Task.sleep(for: .milliseconds(1200))
            capture(settingsController.window, "页面-设置-\(page.title)")
        }
        settingsController.close()
        onboardingController.present()
        for page in OnboardingModel.Page.allCases {
            try? await Task.sleep(for: .milliseconds(1200))
            capture(onboardingController.window, "页面-引导-\(page.rawValue + 1)")
            if page != OnboardingModel.Page.allCases.last { onboardingController.model.next() }
        }
        onboardingController.close()
        helpController.present()
        try? await Task.sleep(for: .milliseconds(1000))
        capture(helpController.window, "页面-帮助")
        helpController.close()
        panelController.show()
        try? await Task.sleep(for: .milliseconds(1200))
        capture(panelController.window, "页面-面板")
        panelController.debugEditor.open(.text(NSAttributedString(string: "示例文本"), isRich: false), on: nil) { _ in }
        try? await Task.sleep(for: .milliseconds(1000))
        capture(window(named: "EditorPanel"), "页面-编辑器")
        window(named: "EditorPanel")?.close()
        panelController.hide()
        if let first = try? store.clips(limit: 3) { stack?.add(first) }
        try? await Task.sleep(for: .milliseconds(1200))
        capture(window(named: "StackPanel"), "页面-Stack")
        print("GALLERY 完成")
        exit(0)
    }

    /// 核对外观用（XPASTE_SNAPSHOT_DIR=<目录>）：把 XPaste 自己的面板、暂停提示、筛选浮层和菜单栏图标画成 PNG，
    /// 不截屏，不会拍到别的应用。玻璃的背景透不出来，只看排版、描边和图标。
    private func writeSnapshots(to directory: URL) async {
        func save(_ root: NSView?, _ name: String) {
            // 玻璃本身画出来是一片白，画它里面的内容。
            func glass(in view: NSView) -> NSGlassEffectView? { (view as? NSGlassEffectView) ?? view.subviews.lazy.compactMap(glass(in:)).first }
            let view = root.flatMap(glass(in:))?.contentView ?? root
            guard let view, let layer = view.layer else { return }
            let scale: CGFloat = 2
            guard let context = CGContext(data: nil, width: Int(view.bounds.width * scale), height: Int(view.bounds.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            // 底下铺一层深灰，代替玻璃透出来的背景。
            context.setFillColor(NSColor(white: 0.18, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
            context.scaleBy(x: scale, y: scale)
            view.effectiveAppearance.performAsCurrentDrawingAppearance { layer.render(in: context) }
            guard let image = context.makeImage() else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
        }
        func saveImages(_ images: [NSImage], _ name: String) {
            let side = images.first?.size ?? .zero
            let strip = NSImage(size: NSSize(width: side.width * CGFloat(images.count) * 4, height: side.height * 4), flipped: false) { _ in
                NSColor.white.setFill()
                NSRect(x: 0, y: 0, width: side.width * CGFloat(images.count) * 4, height: side.height * 4).fill()
                for (index, image) in images.enumerated() {
                    image.draw(in: NSRect(x: side.width * 4 * CGFloat(index), y: 0, width: side.width * 4, height: side.height * 4))
                }
                return true
            }
            guard let tiff = strip.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
        }
        for direct in [true, false] {
            let renderer = ImageRenderer(content: PasteModeIllustration(direct: direct).frame(width: 150, height: 100))
            renderer.scale = 3
            if let image = renderer.cgImage {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("paste-mode-\(direct).png"))
            }
        }
        // 关于页和帮助窗口（第 11 步）。
        settingsController.present(page: .about)
        try? await Task.sleep(for: .seconds(1))
        save(settingsController.window?.contentView, "about")
        settingsController.close()
        helpController.present()
        try? await Task.sleep(for: .seconds(1))
        save(helpController.window?.contentView, "help")
        helpController.close()
        try? await Task.sleep(for: .seconds(1.5))
        save(panelController.debugWindow.contentView, "panel")
        pause(for: 600)
        try? await Task.sleep(for: .seconds(0.5))
        save(StatusHUD.shared.debugWindow?.contentView, "hud-paused")
        save(panelController.debugWindow.contentView, "panel-paused")
        if let statusIcon { saveImages([statusIcon.debugStill], "status-paused") }
        resume()
        try? await Task.sleep(for: .seconds(0.5))
        save(StatusHUD.shared.debugWindow?.contentView, "hud-resumed")
        if let statusIcon {
            saveImages([statusIcon.debugStill], "status")
            saveImages(statusIcon.debugFrames().enumerated().filter { $0.offset % 3 == 0 }.map(\.element), "status-frames")
        }
        panelController.debugToggleFilter()
        try? await Task.sleep(for: .seconds(0.5))
        save(panelController.debugFilterPanel.debugWindow?.contentView, "filter")
        print("SNAPSHOT filter=\(String(describing: panelController.debugFilterPanel.debugWindow?.frame)) bar=\(panelController.debugSearchBarFrame)")
        // 显示中点 × 关掉登录提示，历史卡片前移；下次打开面板时提示回来，卡片还在不在。
        panelController.hide()
        try? await Task.sleep(for: .seconds(0.5))
        panelController.show()
        try? await Task.sleep(for: .seconds(1))
        panelController.debugCloseTip(.openAtLogin)
        try? await Task.sleep(for: .seconds(0.3))
        save(panelController.debugWindow.contentView, "tips-none")
        panelController.hide()
        try? await Task.sleep(for: .seconds(0.5))
        panelController.show()
        try? await Task.sleep(for: .seconds(1))
        save(panelController.debugWindow.contentView, "tips-back")
        let frames = panelController.debugTipAndFirstCardFrames
        print("SNAPSHOT tips=\(frames.tips) card=\(String(describing: frames.card)) loaded=\(panelController.debugLoadedCount)")
        fflush(stdout)
    }

    /// 测试域默认不碰真实剪贴板：不采集，回放写到独立的命名剪贴板、不发 ⌘V。
    /// 真机验证真实采集和粘贴时用 `XPASTE_TEST_CAPTURE=1` 打开，内容进的仍是测试域自己的库。
    static let usesRealClipboard = AppPreferences.testProfile == nil || ProcessInfo.processInfo.environment["XPASTE_TEST_CAPTURE"] == "1"
    #endif

    private static var dataDirectory: URL {
        #if DEBUG
        if let profile = AppPreferences.testProfile {
            return FileManager.default.temporaryDirectory.appendingPathComponent("XPaste-Settings-Test-\(profile)", isDirectory: true)
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if DEBUG
        return base.appendingPathComponent("XPaste-Debug", isDirectory: true)
        #else
        return base.appendingPathComponent("XPaste", isDirectory: true)
        #endif
    }

    /// MCP 默认关闭；开启后只监听本机回环地址。
    private func startMCP() {
        let mcp = MCPController(store: store, directory: Self.dataDirectory)
        mcp.onHistoryChange = { [weak self] in self?.panelController.historyDidChange() }
        mcp.onStack = { [weak self] in self?.stack?.add(ids: $0) }
        self.mcp = mcp
        let settings = MCPSettingsModel(controller: mcp)
        mcpSettings = settings
        Task {
            await mcp.apply()
            settings.refresh()
        }
    }

    /// 应用已在运行时再次打开（访达里双击、`open -a`）就唤出面板，和原版一样。引导还没完成时不弹，引导窗口自己在前面。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard store != nil, !shouldShowOnboarding else { return true }
        if !panelController.isVisible { panelController.show() }
        return false
    }

    private var shouldShowOnboarding: Bool {
        guard !AppPreferences.shared.onboardingCompleted else { return false }
        #if DEBUG
        // 独立测试域默认保持原有验收入口；测全新用户时显式要求。
        if AppPreferences.testProfile != nil { return ProcessInfo.processInfo.environment["XPASTE_ONBOARDING"] == "1" }
        #endif
        return true
    }

    /// 识别语言改了之后，已有图片重新排队识别。
    private func recognizeImagesAgain() throws -> Int {
        let count = try store.requeueTextRecognition()
        if let indexer = ocrIndexer { Task { await indexer.kick() } }
        return count
    }

    /// 改保留期限、删除历史：大库时要删很多行和外置文件，放到后台做，设置窗口不卡（轻量化）。
    /// 失败只记日志：这两步失败时库保持原样，下次每小时的清理会再做一次。
    private func changeRetention(_ period: RetentionPeriod) throws {
        let store = store!
        Task.detached(priority: .userInitiated) {
            do { try store.applyRetention(period) } catch { Log.storage.error("按新的保留期限清理失败: \(String(describing: error))") }
            await MainActor.run { [weak self] in self?.panelController.historyDidChange() }
        }
    }

    private func eraseHistory() {
        // 撤销栈和预览先清掉：它们指向的条目马上就没了。
        panelController.historyWasErased()
        let store = store!
        Task.detached(priority: .userInitiated) {
            do { try store.eraseHistory() } catch { Log.storage.error("删除历史失败: \(String(describing: error))") }
            await MainActor.run { [weak self] in self?.panelController.historyDidChange() }
        }
    }

    private func setShortcutRecording(_ recording: Bool) -> String? {
        do { try shortcutRegistry.setRecording(recording); return nil }
        catch { return error.localizedDescription }
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow { WindowSharing.apply(to: window) }
    }

    private func applyPrivacySettings() {
        monitor.policy = AppPreferences.shared.capturePolicy
        for window in NSApp.windows { WindowSharing.apply(to: window) }
        panelController.privacyDidChange()
        if let linkIndexer { Task { await linkIndexer.settingsDidChange() } }
    }

    // MARK: 采集

    /// 入库（算校验和、生成缩略图、写库）放到后台：几十 MB 的图片或文本在主线程上要卡两三百毫秒（M5 第 3 步实测）。
    /// 一次复制超过这么大就不记（审查 GH-04）：几百 MB 的内容进历史会长时间占内存和磁盘，排队等入库时还会叠加。
    /// 读剪贴板时的那一次分配避免不了，这里挡住的是之后的编码、缩略图和入库。
    static let maxCaptureBytes = 256 * 1024 * 1024

    private func capture(_ snapshot: ClipSnapshot) {
        guard snapshot.byteCount <= Self.maxCaptureBytes else {
            Log.capture.notice("这次复制有 \(snapshot.byteCount / 1_048_576) MB，超过上限，不记录")
            return
        }
        let previous = lastCapture
        let store = store!
        lastCapture = Task { [weak self] in
            await previous?.value
            let result = await Task.detached(priority: .userInitiated) { Result { try Log.measure("record") { try store.record(snapshot) } } }.value
            guard let self else { return }
            switch result {
            case .success(let summary):
                self.panelController.historyDidChange()
                if summary.kind == .text { self.kickRichRefresh() }
                // Stack 开着时，这次复制同时排进队列。
                self.stack?.collect(snapshot, summary: summary)
                SoundEffects.shared.play(.copy)
                self.statusIcon?.playCapture()
                if snapshot.kind == .image, let ocrIndexer = self.ocrIndexer { Task { await ocrIndexer.kick() } }
                if snapshot.kind == .link, let linkIndexer = self.linkIndexer { Task { await linkIndexer.kick() } }
            case .failure(let error):
                Log.capture.error("保存剪贴板内容失败: \(String(describing: error))")
            }
        }
    }

    // MARK: 保留期限

    /// 启动时清一次，之后每小时一次；不在每次采集时扫库。
    private func scheduleRetention() {
        applyRetention()
        let timer = Timer(timeInterval: 3_600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyRetention() }
        }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        retentionTimer = timer
    }

    /// 启动时和每小时的过期清理放在后台（审查 05）：大库或外置文件多时要查库、删数据和文件，不占主线程。
    /// 永久保留时存储层直接返回。清理之后空闲页多了就整理库文件（L92）。
    private func applyRetention() {
        let store = store!
        let period = AppPreferences.shared.retention
        guard period != .forever else { return }
        Task.detached(priority: .utility) {
            do { try store.applyRetention(period) } catch { Log.storage.error("清理过期历史失败: \(String(describing: error))") }
            do { try store.compactIfNeeded() } catch { Log.storage.error("整理数据库失败: \(String(describing: error))") }
            await MainActor.run { [weak self] in self?.panelController.historyDidChange() }
        }
    }

    // MARK: 菜单栏

    @objc private func showSettings() {
        // 启动时被占用的全局快捷键在这里再试一次；仍失败时快捷键页保存同一组合会给出原因。
        try? shortcutRegistry.apply(AppPreferences.shared.keyboardSettings)
        panelController.hide { [weak self] in self?.settingsController.present() }
    }

    @objc private func showAbout() {
        panelController.hide { [weak self] in self?.settingsController.present(page: .about) }
    }

    private let helpWindow = OnDemandWindow { HelpWindowController() }
    private var helpController: HelpWindowController { helpWindow.controller }

    @objc private func showHelp() {
        panelController.hide { [weak self] in self?.helpController.present() }
    }

    private func setUpApplicationMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let about = NSMenuItem(title: String(localized: "关于 XPaste"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: String(localized: "设置…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(NSMenuItem(title: String(localized: "退出 XPaste"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        menu.addItem(appItem)
        // 应用在前台时（设置窗口、确认框、应用选择面板）文本框依赖“编辑”菜单的标准快捷键。
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: String(localized: "编辑"))
        editMenu.addItem(NSMenuItem(title: String(localized: "撤销"), action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: String(localized: "重做"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: String(localized: "剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: String(localized: "拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: String(localized: "粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: String(localized: "全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        menu.addItem(editItem)
        // 应用在前台时菜单栏里的“帮助”。系统会在这个菜单里自动加上搜索框。
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: String(localized: "帮助"))
        let help = NSMenuItem(title: String(localized: "XPaste 帮助"), action: #selector(showHelp), keyEquivalent: "?")
        help.target = self
        helpMenu.addItem(help)
        helpItem.submenu = helpMenu
        menu.addItem(helpItem)
        NSApp.helpMenu = helpMenu
        NSApp.mainMenu = menu
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusIcon = StatusIcon(button: item.button)
        // 左键直接开关面板，右键（或按住 Control 点）才弹菜单。
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusMenu.delegate = self
        statusItem = item
    }

    private let statusMenu = NSMenu()

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return togglePanel() }
        let wantsMenu = event.type == .rightMouseUp || event.modifierFlags.contains(.control)
        guard wantsMenu, let item = statusItem else { return togglePanel() }
        // 临时挂上菜单再模拟一次点击，菜单就按系统的样式从图标下方弹出；关掉后摘下，左键仍是开关面板。
        item.menu = statusMenu
        sender.performClick(nil)
        item.menu = nil
    }

    private func registerHotKey() {
        do { try shortcutRegistry.load(AppPreferences.shared.keyboardSettings) }
        catch {
            Log.app.error("注册全局快捷键失败: \(error.localizedDescription)")
            #if DEBUG
            if AppPreferences.testProfile != nil { return }
            #endif
            // 后台应用的模态框不会自己到前台，可能被其他窗口挡住。
            AppActivation.bringToFront()
            NSAlert.showMessage(String(localized: "快捷键不可用"), detail: error.localizedDescription)
        }
    }

    private func togglePanel() {
        panelController.toggle()
    }

    /// Stack 快捷键：面板开着、有选中项时，用选中项创建或追加 Stack（Docs/归档/验收记录/Stack改版.md S4）；否则开关 Stack。
    private func stackShortcutPressed() {
        if panelController.isVisible, panelController.addSelectionToStack() { return }
        stack?.toggle()
    }

    /// 别的应用拖进 Stack 的内容：和复制来的一样存进历史、补识别和链接信息，但不再自动排进 Stack（由 Stack 放到松手处）。
    private func recordDropped(_ snapshot: ClipSnapshot) async -> ClipSummary? {
        guard snapshot.byteCount <= Self.maxCaptureBytes else { return nil }
        let store = store!
        await lastCapture?.value
        guard let summary = try? await Task.detached(priority: .userInitiated, operation: { try store.record(snapshot) }).value else {
            NSSound.beep()
            return nil
        }
        panelController.historyDidChange()
        if summary.kind == .text { kickRichRefresh() }
        if snapshot.kind == .image, let ocrIndexer { Task { await ocrIndexer.kick() } }
        if snapshot.kind == .link, let linkIndexer { Task { await linkIndexer.kick() } }
        return summary
    }

    /// 只有 HTML 的文本条目（WPS、Codex 等）补写卡片缓存（v8-rich-refresh，L179）：入库时标成待补写，
    /// 存储层在后台取出 HTML，回到主线程转换（WebKit），再到后台写入；字符数仍按纯文本（用户决定）。
    /// 从最新的一条往前逐条做；HTML 转换之间让出主线程，不影响面板操作。每补好 20 条刷新一次面板，做完再刷新一次。
    private var richRefreshTask: Task<Void, Never>?
    /// 补写期间又有新条目入库：这一轮做完后再查一遍，免得在“刚查完没有了、还没退出”的空当里漏掉。
    private var richRefreshAgain = false

    /// 启动时和每次有文本条目入库后调用。已经在做就只记下来，由这一轮接着做。
    private func kickRichRefresh() {
        guard richRefreshTask == nil else {
            richRefreshAgain = true
            return
        }
        let store = store!
        richRefreshTask = Task { [weak self] in
            var processed = 0, changed = 0, pendingRefresh = 0
            let started = ContinuousClock.now
            while true {
                let next = await Task.detached(priority: .utility) { () -> Result<(HistoryStore.RichRefreshJob, HistoryStore.RichRefreshStep)?, Error> in
                    Result {
                        guard let job = try store.nextTextAwaitingRichRefresh() else { return nil }
                        return (job, try store.refreshRich(job))
                    }
                }.value
                guard let self else { return }
                guard case .success(let step) = next else {
                    if case .failure(let error) = next { Log.capture.error("补写卡片缓存失败: \(String(describing: error))") }
                    break
                }
                guard let (job, result) = step else {
                    // 查完没有了：期间有新条目入库的话再查一遍。
                    if self.richRefreshAgain { self.richRefreshAgain = false; continue }
                    break
                }
                processed += 1
                switch result {
                case .done:
                    break
                case .needsHTML(let html):
                    // 超过 2 MB、转不出来的记成没有缓存，仍显示纯文本。
                    let data = Log.measure("html-preview") { RichText.decodeHTML(html) }.flatMap(HistoryStore.richPreviewData)
                    let filled = await Task.detached(priority: .utility) { (try? store.finishRichRefresh(job, richPreview: data)) ?? false }.value
                    if filled { changed += 1; pendingRefresh += 1 }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                if pendingRefresh >= 20 {
                    pendingRefresh = 0
                    self.panelController.historyDidChange()
                }
            }
            self?.richRefreshTask = nil
            self?.richRefreshAgain = false
            if pendingRefresh > 0 { self?.panelController.historyDidChange() }
            if processed > 1 {
                Log.capture.notice("卡片缓存补写完成：\(processed) 条，更新 \(changed) 条，用时 \(String(describing: ContinuousClock.now - started))")
            }
        }
    }

    /// 锁屏、切换用户（审查 10，用户决定）：期间暂停记录，收起面板和预览；回来自动恢复。Stack 保留。
    /// 用户自己的暂停不受影响：锁屏前已暂停的，解锁后仍是暂停。
    ///
    /// 锁屏、解锁是分布式通知，必须注册成“立即送达”（L168）：AppKit 在应用被激活过、又退到后台后会暂停接收分布式通知，
    /// 同名的合并、等下次激活才补发，补发顺序还可能是“先解锁、后锁”。XPaste 打开设置、帮助、说明框时会被激活，
    /// 之后就收不到实时的锁屏和解锁，状态可能停在“锁着”，采集被悄悄暂停（小样实测复现）。
    /// 切换用户的通知走 NSWorkspace 的普通通知中心，不受影响。
    private func observeSessionActivity() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setSessionInactive(true, because: "切换到别的用户") }
        }
        workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setSessionInactive(false, because: "切换回本用户") }
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screenDidLock(_:)), name: Self.screenLocked, object: nil,
                                suspensionBehavior: .deliverImmediately)
        distributed.addObserver(self, selector: #selector(screenDidUnlock(_:)), name: Self.screenUnlocked, object: nil,
                                suspensionBehavior: .deliverImmediately)
    }

    static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    @objc private func screenDidLock(_ notification: Notification) { setSessionInactive(true, because: "锁屏") }
    @objc private func screenDidUnlock(_ notification: Notification) { setSessionInactive(false, because: "解锁") }

    private func setSessionInactive(_ inactive: Bool, because reason: String) {
        guard sessionInactive != inactive else { return }
        Log.capture.notice("会话\(inactive ? "离开" : "回来", privacy: .public)（\(reason, privacy: .public)）")
        sessionInactive = inactive
        if inactive { panelController.hide() }
        applyCapturePause()
    }

    /// 记录是否暂停 = 用户暂停或会话不在前台。只在状态真的变了时通知监视器（它会对齐计数，暂停期间的复制不补录）。
    private func applyCapturePause() {
        let paused = userPaused || sessionInactive
        guard monitor.isPaused != paused else { return }
        if paused {
            let why = [userPaused ? "手动暂停" : nil, sessionInactive ? "锁屏或切换用户" : nil].compactMap { $0 }.joined(separator: "、")
            Log.capture.notice("暂停记录：\(why, privacy: .public)")
        } else {
            Log.capture.notice("恢复记录")
        }
        monitor.setPaused(paused)
    }

    /// 暂停采集。给了时长就到点自动恢复；暂停期间的复制不补录。
    private func pause(for duration: TimeInterval?) {
        pausedUntil = duration.map { Date().addingTimeInterval($0) }
        userPaused = true
        applyCapturePause()
        scheduleResume()
        updatePauseUI()
        StatusHUD.shared.showPause(true, until: pausedUntil)
    }

    /// 按 `pausedUntil` 排好自动恢复。计时器按开机运行时间走，睡眠期间不计时，
    /// 所以醒来时再排一次：已经过了时间就立即恢复，否则按剩余时间重排。
    private func scheduleResume() {
        resumeTimer?.invalidate()
        resumeTimer = nil
        guard let pausedUntil else { return }
        let remaining = pausedUntil.timeIntervalSinceNow
        guard remaining > 0 else { return resume() }
        let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        }
        RunLoop.main.add(timer, forMode: .common)
        resumeTimer = timer
    }

    private func resume() {
        resumeTimer?.invalidate()
        resumeTimer = nil
        pausedUntil = nil
        let wasPaused = userPaused
        userPaused = false
        applyCapturePause()
        updatePauseUI()
        if wasPaused { StatusHUD.shared.showPause(false) }
    }

    /// 菜单栏图标右下角的暂停标记、面板左上角的暂停图标。
    private func updatePauseUI() {
        statusIcon?.isPaused = userPaused
        panelController.pauseStateDidChange()
    }


    // MARK: 回放

    /// 只放进了剪贴板、没有直接粘贴时的提示（原版如此）。还没允许直接粘贴时提示里可以点去开启。
    private func showCopied(skippedFiles: Int = 0) {
        if skippedFiles > 0 { return StatusHUD.shared.showSkippedFiles(skippedFiles, pasted: false) }
        StatusHUD.shared.showCopied(offerDirectPaste: DirectPastePermission.isTrusted ? nil : { PastePerformer.requestTrust() })
    }

    /// 回放一条或多条（多选）。多条时按原版的规则合成一份内容，见 `MultiSelection`。
    /// 每次回放加一。等待中又发起了新的回放时，旧的那次不再写剪贴板或发送 ⌘V（审查 01）。
    private var pasteRequest = 0

    private func paste(_ clips: [ClipSummary], plainText: Bool, direct: Bool, target: NSRunningApplication?) {
        pasteRequest += 1
        let request = pasteRequest
        let store = store!
        // 从发起回放到发出 ⌘V（或放弃）的整段耗时。
        let pasteSignpost = Log.signposter.beginInterval("paste", id: Log.signposter.makeSignpostID(), "\(clips.count) 条")
        Task {
            defer { Log.signposter.endInterval("paste", pasteSignpost) }
            // 读库、取外置文件、另存图片、合并文本都在后台做（审查 05），主线程只写剪贴板和发键。
            let composed = await Task.detached(priority: .userInitiated) { () -> ClipSnapshot? in
                var snapshots = clips.compactMap { try? store.snapshot(id: $0.id) }
                guard snapshots.count == clips.count else { return nil }
                // 多选里没有文本时每项各占一个 item；图片另存成文件并附上地址，才能粘进访达（原版如此，L32）。
                if snapshots.count > 1, !snapshots.contains(where: { [.text, .link, .color].contains($0.kind) }) {
                    snapshots = zip(snapshots, clips).map { snapshot, clip in
                        clip.kind == .image ? ImageFiles.attachingFiles(to: snapshot, name: clip.sourceName) : snapshot
                    }
                }
                return MultiSelection.compose(snapshots)
            }.value
            guard request == pasteRequest else { return }
            guard var snapshot = composed else {
                Log.paste.error("条目 \(clips.map(\.id), privacy: .public) 的内容读不出来，放弃回放")
                NSSound.beep()
                return
            }

            // 文件类先确认每个文件都能访问；否则系统会把文件 URL 静默去掉，粘贴出来是空的。
            // 有的能用、有的不能用时只交出能用的部分，事后提示少了几个（审查 11，用户决定）；一个都用不了才弹框说明原因。
            var skippedFiles = 0
            if !snapshot.fileURLs.isEmpty {
                let access = await FileAccess.check(snapshot.fileURLs)
                guard request == pasteRequest else { return }
                if !access.isUsable {
                    guard let usable = snapshot.removingFiles(access.unusable) else {
                        FileAccess.presentFailure(access)
                        return
                    }
                    skippedFiles = access.unusable.count
                    snapshot = usable
                }
            }

            var pasteboard = NSPasteboard.general
            #if DEBUG
            if !Self.usesRealClipboard, let profile = AppPreferences.testProfile {
                pasteboard = NSPasteboard(name: .init("com.mars.XPaste.settings-test.\(profile)"))
            }
            #endif
            guard let changeCount = PasteboardWriter.write(snapshot, to: pasteboard, plainTextOnly: plainText) else {
                Log.paste.error("写入剪贴板失败，放弃回放")
                NSSound.beep()
                return
            }
            monitor.acknowledge(changeCount: changeCount)
            // 用过的条目回到历史最前，多条时彼此的顺序不变。
            try? store.touch(ids: clips.map(\.id))

            // 未授权时内容已在剪贴板里，用户可手动 ⌘V。这种情况和“复制”一样只响复制的音。
            guard direct, let target, !target.isTerminated else {
                SoundEffects.shared.play(.copy)
                showCopied(skippedFiles: skippedFiles)
                return
            }
            guard DirectPastePermission.isTrusted else {
                SoundEffects.shared.play(.copy)
                let requestedTrust = directPastePermission.explainIfNeeded(appName: target.localizedName)
                // 暂不授权时把焦点还给原应用，用户可直接手动 ⌘V。
                if !requestedTrust {
                    if !target.isTerminated { target.activate() }
                    showCopied(skippedFiles: skippedFiles)
                }
                return
            }
            #if DEBUG
            // 独立测试剪贴板不向真实应用发送 ⌘V。
            if !Self.usesRealClipboard { return }
            #endif
            // 面板不激活应用，目标通常仍在前台；被别的应用抢走时才需要重新激活。
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
                target.activate()
                try? await Task.sleep(for: .milliseconds(120))
            }
            // 发 ⌘V 前最后一刻复核：前台还是目标、剪贴板还是这次写的内容（期间没有新复制）、没有更新的回放请求。
            // 任何一项不成立都不发，内容留在剪贴板里，提示已复制，由用户自己粘贴。
            let pid = target.processIdentifier
            let posted = PastePerformer.postPaste {
                request == self.pasteRequest && pasteboard.changeCount == changeCount
                    && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            }
            if posted {
                SoundEffects.shared.play(.paste)
                if skippedFiles > 0 { StatusHUD.shared.showSkippedFiles(skippedFiles, pasted: true) }
            } else if request == pasteRequest {
                // 只记哪项复核没通过，不记内容。
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                Log.paste.notice("没有自动粘贴，只留在剪贴板：前台是目标 \(front == pid, privacy: .public)，剪贴板未变 \(pasteboard.changeCount == changeCount, privacy: .public)，已授权 \(PastePerformer.isTrusted, privacy: .public)")
                SoundEffects.shared.play(.copy)
                showCopied(skippedFiles: skippedFiles)
            } else {
                Log.paste.notice("没有自动粘贴：被更新的粘贴请求取代")
            }
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    /// 菜单栏图标的右键菜单每次打开时重建，内容与面板里的更多菜单一致，暂停状态因此总是最新的。左键是开关面板，菜单里不再有“显示 XPaste”。
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let stackTitle = stack?.isOpen == true ? String(localized: "关闭 Stack") : String(localized: "打开 Stack")
        menu.addItem(ClosureMenuItem(stackTitle) { [weak self] in self?.stack?.toggle() })
        if !PastePerformer.isTrusted {
            menu.addItem(ClosureMenuItem(String(localized: "启用直接粘贴…")) { PastePerformer.requestTrust() })
        }
        menu.addItem(.separator())
        panelController.addMoreMenuItems(to: menu)
    }
}
