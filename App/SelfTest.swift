#if DEBUG
import AppKit
import WebKit
import ClipboardKit
import Network
import PasteCore
import SwiftUI

/// 调试构建的自检：`XPASTE_SELFTEST=1` 启动时在临时数据目录里跑一遍，把结果打印到标准输出后退出。
/// 覆盖计划里不便手工做的验收项：大数据量下的唤起耗时、反复开关后的资源数量、新内容到达时选中不变。
@MainActor
enum SelfTest {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["XPASTE_SELFTEST"] == "1" }

    static func prepareSettingsVerification(store: HistoryStore) throws {
        guard try store.pinboards().isEmpty else { return }
        let board = try store.createPinboard(name: "设置验收", colorHex: "#4B8DF7")
        func record(_ value: String, daysAgo: Double) throws -> ClipSummary {
            try store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [
                ClipRepresentation(type: ClipType.plainText, data: Data(value.utf8))
            ])]), now: Date().addingTimeInterval(-daysAgo * 86_400))
        }
        let pinned = try record("已固定的旧历史", daysAgo: 15)
        try store.pin(ids: [pinned.id], to: board.id)
        _ = try record("未固定的旧历史", daysAgo: 15)
        _ = try record("最近的历史", daysAgo: 0)
        let environment = ProcessInfo.processInfo.environment
        if environment["XPASTE_SEED_KINDS"] == "1" { try seedAllKinds(store) }
        // 真机验证用：一批 Pinboard（页签滚动）、一条指定的链接（网页预览）。
        if let count = environment["XPASTE_SEED_PINBOARDS"].flatMap(Int.init), count > 0 {
            for index in 1...min(count, 60) { _ = try store.createPinboard(name: "页签 \(index)", colorHex: "#4B8DF7") }
        }
        // 筛选浮层的“更多”要来源应用超过 8 个：每个来源一条文本，用本机装着的应用。
        if let count = environment["XPASTE_SEED_SOURCES"].flatMap(Int.init), count > 0 {
            let candidates = ["com.apple.Safari", "com.apple.finder", "com.apple.Notes", "com.apple.mail", "com.apple.Terminal", "com.apple.Preview",
                              "com.apple.TextEdit", "com.apple.iCal", "com.apple.Maps", "com.apple.Music", "com.apple.Photos", "com.apple.reminders",
                              "com.apple.systempreferences", "com.apple.AppStore", "com.apple.FaceTime", "com.apple.Contacts"]
            let installed = candidates.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
            for (index, bundleID) in installed.prefix(count).enumerated() {
                let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { FileManager.default.displayName(atPath: $0.path) }
                    .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
                _ = try store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [
                    ClipRepresentation(type: ClipType.plainText, data: Data("来源 \(index + 1) 的内容".utf8))])], sourceBundleID: bundleID, sourceName: name),
                    now: Date().addingTimeInterval(-Double(index) * 3_600))
            }
        }
        if let url = environment["XPASTE_SEED_URL"], !url.isEmpty {
            _ = try store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.plainText, data: Data(url.utf8))])],
                                              sourceBundleID: "com.apple.Safari", sourceName: "Safari"))
        }
        let capturing = ProcessInfo.processInfo.environment["XPASTE_TEST_CAPTURE"] == "1"
        print("SETTINGS TEST: \(AppPreferences.testProfile ?? "")；独立数据；\(capturing ? "采集剪贴板" : "不采集剪贴板")")
    }

    /// 外观验收用：每种类型各放一条（带透明区域的横图、很深的文件路径、颜色、链接），看卡片的各种版式。
    private static func seedAllKinds(_ store: HistoryStore) throws {
        func record(_ type: String, _ data: Data, source: String) throws {
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source).map { FileManager.default.displayName(atPath: $0.path) }
            _ = try store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [ClipRepresentation(type: type, data: data)])],
                                              sourceBundleID: source, sourceName: name))
        }
        let image = NSImage(size: NSSize(width: 300, height: 120), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 90, dy: 10)).fill()
            return true
        }
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try record(ClipType.png, png, source: "com.apple.Preview")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("XPaste-Settings-Test-kinds/Library/Containers/com.example.LongName/Data/Documents/projects/2026-11/report")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("季度报告.txt")
        try Data("测试".utf8).write(to: file)
        try record(ClipType.fileURL, Data(file.absoluteString.utf8), source: "com.apple.finder")
        try record(ClipType.plainText, Data("#3366CC".utf8), source: "com.apple.dt.Xcode")
        try record(ClipType.plainText, Data("https://example.com/xpaste/kinds".utf8), source: "com.apple.Safari")
        try record(ClipType.plainText, Data("终端里复制的一行".utf8), source: "com.apple.Terminal")
        // 带格式的文本：衬线体、写死黑色的一段，加粗放大的红字，斜体下划线的结尾。
        let rich = NSMutableAttributedString(string: "Rich plain ", attributes: [.font: NSFont(name: "Times New Roman", size: 13) ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.black])
        rich.append(NSAttributedString(string: "BOLD RED", attributes: [.font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.systemRed]))
        rich.append(NSAttributedString(string: " italic tail", attributes: [.font: NSFontManager.shared.convert(.systemFont(ofSize: 13), toHaveTrait: .italicFontMask), .underlineStyle: 1]))
        if let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]) {
            _ = try store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [
                ClipRepresentation(type: ClipType.plainText, data: Data(rich.string.utf8)), ClipRepresentation(type: ClipType.rtf, data: rtf),
            ])], sourceBundleID: "com.apple.TextEdit", sourceName: "文本编辑"))
        }
    }

    static func run() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xpaste-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL") \(name) \(detail)")
            if !ok { failures += 1 }
        }

        do {
            // 设置的迁移和持久化只用独立偏好域，不碰真实设置。
            let suite = "com.mars.XPaste.selftest.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let preferences = AppPreferences(defaults: defaults)
            check("通用设置默认值", preferences.soundEffectsEnabled && preferences.pasteToApplication
                  && !preferences.alwaysPastePlainText && preferences.retention == .month)
            check("MCP 默认关闭、默认端口 39725", !preferences.mcpEnabled && preferences.mcpPort == 39725)
            defaults.set("week", forKey: "historyRetention")
            defaults.set(false, forKey: "soundEffectsEnabled")
            check("沿用已有偏好键", preferences.retention == .week && !preferences.soundEffectsEnabled)
            preferences.retention = .forever
            preferences.pasteToApplication = false
            preferences.alwaysPastePlainText = true
            let reloaded = AppPreferences(defaults: UserDefaults(suiteName: suite)!)
            check("设置写入后可重新读取", reloaded.retention == .forever && !reloaded.pasteToApplication && reloaded.alwaysPastePlainText)
            let privateTypes: Set<String> = ["org.nspasteboard.ConcealedType"]
            check("隐私默认过滤与默认忽略应用", preferences.showDuringScreenSharing && preferences.generateLinkPreviews
                  && preferences.capturePolicy.decide(types: privateTypes, sourceBundleID: nil) == .skip(.confidential)
                  && preferences.ignoredBundleIDs == ["com.apple.Passwords", "com.apple.keychainaccess"])
            preferences.ignoreConfidential = false
            preferences.ignoreTransient = false
            preferences.ignoredBundleIDs = ["com.example.ignored"]
            check("隐私偏好映射到实际采集策略", preferences.capturePolicy.decide(types: privateTypes, sourceBundleID: nil) == .capture
                  && preferences.capturePolicy.decide(types: ["org.nspasteboard.TransientType"], sourceBundleID: nil) == .capture
                  && preferences.capturePolicy.decide(types: [], sourceBundleID: "com.example.ignored") == .skip(.ignoredApp)
                  && preferences.capturePolicy.decide(types: [CapturePolicy.selfMarker], sourceBundleID: nil) == .skip(.ownWrite))
            preferences.showDuringScreenSharing = false
            let sharingProbe = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
            WindowSharing.apply(to: sharingProbe, preferences: preferences)
            check("关闭共享可见时设置窗口标记", sharingProbe.sharingType == .none)
            preferences.showDuringScreenSharing = true
            WindowSharing.apply(to: sharingProbe, preferences: preferences)
            check("恢复共享可见时还原窗口标记", sharingProbe.sharingType == .readOnly)
            preferences.ignoreConfidential = true
            preferences.ignoreTransient = true

            PermissionSelfTest.run(preferences: preferences, check: check)
            try KeyboardSelfTest.run(preferences: preferences, check: check)
            try OnboardingSelfTest.run(preferences: preferences, check: check)
            try await MCPSelfTest.run(preferences: preferences, check: check)

            var retained: RetentionPeriod?
            var erased = false
            let settings = SettingsWindowController(preferences: preferences, savesFrame: false, onRetention: { retained = $0 }, onEraseHistory: { erased = true })
            let settingsContent = settings.window!.contentView!
            check("设置整窗尺寸 640 × 592", settings.window!.frame.size == NSSize(width: 640, height: 592))
            for _ in 0..<10 { settings.present(); settings.close() }
            check("设置窗口关闭后可重用", settings.window?.contentView === settingsContent && retained == nil && !erased)

            let store = try HistoryStore(directory: directory)
            let count = 10_000
            let base = Date().addingTimeInterval(-Double(count) * 60)
            let png = makePNG()
            for i in 0..<count {
                let rep: ClipRepresentation = i % 20 == 0
                    ? ClipRepresentation(type: ClipType.png, data: png + Data("\(i)".utf8))
                    : ClipRepresentation(type: ClipType.plainText, data: Data("自检条目 \(i) " .utf8) + Data(String(repeating: "lorem ipsum 填充 ", count: i % 30).utf8))
                try store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [rep])], sourceBundleID: "com.apple.finder", sourceName: "Finder"),
                                 now: base.addingTimeInterval(Double(i) * 60))
            }
            print("INFO 已写入 \(count) 条")

            let panel = PanelController(store: store, preferences: preferences)
            panel.animationsEnabled = false

            let privacyLink = try store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [
                ClipRepresentation(type: ClipType.plainText, data: Data("http://127.0.0.1/privacy-test".utf8))
            ])]))
            if let job = try store.nextLinkAwaitingMetadata() {
                _ = try store.setLinkMetadata(LinkMetadata(title: "已缓存的链接标题"), for: job)
            }
            panel.show()
            await panel.debugSettle()
            panel.debugPress(keyCode: 49, characters: " ")
            await panel.debugSettle()
            preferences.generateLinkPreviews = false
            panel.privacyDidChange()
            check("关闭链接开关立即关闭现有预览", panel.debugPreviewClipID == nil)
            check("关闭链接开关保留既有卡片元数据", try store.summary(id: privacyLink.id)?.linkTitle == "已缓存的链接标题")
            panel.hide()
            preferences.generateLinkPreviews = true

            var replayFlags: (plain: Bool, direct: Bool)?
            panel.onPaste = { _, plain, direct, _ in replayFlags = (plain, direct) }
            // 回放在面板收起动画结束后才调用，按键后要等它来，不能只等列表查询（L104：曾偶发读到上一次的参数）。
            func pressAndAwaitReplay(_ modifiers: NSEvent.ModifierFlags = []) async {
                replayFlags = nil
                panel.show()
                await panel.debugSettle()
                panel.debugPress(keyCode: 36, modifiers: modifiers)
                let start = ContinuousClock.now
                while replayFlags == nil, ContinuousClock.now - start < .seconds(2) { try? await Task.sleep(for: .milliseconds(10)) }
            }
            await pressAndAwaitReplay()
            check("剪贴板模式与默认纯文本即时生效", replayFlags?.plain == true && replayFlags?.direct == false)
            preferences.pasteToApplication = true
            preferences.alwaysPastePlainText = false
            await pressAndAwaitReplay()
            check("恢复直接粘贴即时生效", replayFlags?.plain == false && replayFlags?.direct == true)
            await pressAndAwaitReplay(.shift)
            check("临时纯文本粘贴仍可用", replayFlags?.plain == true && replayFlags?.direct == true)
            panel.show()
            await panel.debugSettle()
            panel.debugPress(keyCode: 8, characters: "c", modifiers: .command)
            await panel.debugSettle()
            check("复制命令仍然只复制", replayFlags?.direct == false)
            panel.onPaste = nil

            try await KeyboardSelfTest.checkPanel(store: store, preferences: preferences, check: check)

            // 1. 唤起到首帧布局完成的耗时
            var samples: [Double] = []
            for _ in 0..<30 {
                let start = CACurrentMediaTime()
                panel.show()
                await panel.debugSettle()
                panel.debugForceLayout()
                samples.append((CACurrentMediaTime() - start) * 1_000)
                panel.hide()
            }
            samples.sort()
            let p95 = samples[Int(Double(samples.count) * 0.95) - 1]
            check("热唤起到首帧 p95 ≤ 100 ms", p95 <= 100, String(format: "p50=%.1f ms p95=%.1f ms 最大=%.1f ms", samples[samples.count / 2], p95, samples.last!))

            // 2. 新内容到达时选中项不变
            panel.show()
            await panel.debugSettle()
            panel.debugSelect(index: 3)
            await panel.debugSettle()
            let selected = panel.debugSelectedID
            try store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.plainText, data: Data("新到达的内容".utf8))])]))
            panel.historyDidChange()
            await panel.debugSettle()
            check("新内容到达后选中项不变", selected != nil && panel.debugSelectedID == selected, "选中 ID \(selected.map(String.init) ?? "nil") → \(panel.debugSelectedID.map(String.init) ?? "nil")")
            check("新内容排在最前且原选中项后移一位", panel.debugSelectedIndex == 4, "选中序号 \(panel.debugSelectedIndex.map(String.init) ?? "nil")")
            panel.hide()

            // 2b. 查询在后台执行（L45）：主线程不等查询；只采用最后一次请求的结果；结果没回来就按回车，作用于新结果；收起后迟到的结果作废。
            panel.show()
            await panel.debugSettle()
            var searchCalls: [Double] = []
            for term in ["自检", "条目 9", "lorem", "填充"] {
                let start = CACurrentMediaTime()
                panel.debugSearch(term)
                searchCalls.append((CACurrentMediaTime() - start) * 1_000)
                await panel.debugSettle()
            }
            check("搜索时主线程不等查询", searchCalls.max()! < 5, String(format: "发起查询最长 %.2f ms", searchCalls.max()!))
            panel.debugSearch("条目 1 ")
            panel.debugSearch("新到达")
            await panel.debugSettle()
            check("连续搜索只采用最后一次的结果", panel.debugVisiblePreviews.first?.hasPrefix("新到达") == true && panel.debugVisiblePreviews.count == 1,
                  "\(panel.debugVisiblePreviews.prefix(3))")
            var pendingPaste: [String] = []
            panel.onPaste = { clips, _, _, _ in pendingPaste = clips.map(\.previewText) }
            panel.show()
            await panel.debugSettle()
            let oldFirst = panel.debugVisiblePreviews.first
            // 只有第 4242 条匹配；旧列表（未搜索）的第一条是别的内容。
            panel.debugSearch("自检条目 4242")
            let wasPending = panel.debugQueryPending
            panel.debugPress(keyCode: 36)
            await panel.debugSettle()
            for _ in 0..<200 where pendingPaste.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
            check("结果未到时按回车，粘贴的是新结果", wasPending && oldFirst?.hasPrefix("自检条目 4242 ") == false
                  && pendingPaste.count == 1 && pendingPaste.first?.hasPrefix("自检条目 4242 ") == true, "\(pendingPaste.map { String($0.prefix(12)) })")
            panel.onPaste = nil
            panel.show()
            await panel.debugSettle()
            panel.debugSearch("自检")
            panel.hide()
            await panel.debugSettle()
            check("收起后迟到的查询结果作废", panel.debugVisiblePreviews.isEmpty && !panel.debugQueryPending)

            // 3. 预览浮层：空格开关、方向键跟随、Esc 只关预览、面板隐藏时一并关闭
            try store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.plainText, data: Data("#3366CC".utf8))])]))
            panel.show()
            await panel.debugSettle()
            panel.debugPress(keyCode: 49, characters: " ")
            await panel.debugSettle()
            check("空格打开所选条目的预览", panel.debugPreviewClipID != nil && panel.debugPreviewClipID == panel.debugSelectedID)
            panel.debugPress(keyCode: 124)
            await panel.debugSettle()
            check("预览打开时方向键切换条目，预览跟随", panel.debugSelectedIndex == 1 && panel.debugPreviewClipID == panel.debugSelectedID,
                  "选中序号 \(panel.debugSelectedIndex.map(String.init) ?? "nil")")
            panel.debugPress(keyCode: 53)
            await panel.debugSettle()
            check("Esc 只关预览，面板保留", panel.debugPreviewClipID == nil && panel.isVisible)
            panel.debugPress(keyCode: 49, characters: " ")
            await panel.debugSettle()
            panel.debugPress(keyCode: 49, characters: " ")
            await panel.debugSettle()
            check("再按空格关闭预览", panel.debugPreviewClipID == nil && panel.isVisible)
            panel.debugPress(keyCode: 49, characters: " ")
            await panel.debugSettle()
            panel.hide()
            check("面板隐藏时预览一并关闭", panel.debugPreviewClipID == nil && !panel.isVisible)

            // 3b. 文件和链接预览：大浮层；文件不存在、内网地址都不出错，也不发请求
            var large = NSSize.zero
            let note = directory.appendingPathComponent("selftest-note.txt")
            try Data("selftest file".utf8).write(to: note)
            func fileClip(_ urls: [URL]) -> ClipSnapshot {
                ClipSnapshot(items: urls.map { ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.fileURL, data: Data($0.absoluteString.utf8))]) })
            }
            // XPASTE_SELFTEST_SHOTS 指向一个目录时，顺便把各种卡片和预览离屏画出来。
            let shots = ProcessInfo.processInfo.environment["XPASTE_SELFTEST_SHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            var shotIndex = 0
            func previewSize(of snapshot: ClipSnapshot) async throws -> NSSize? {
                try store.record(snapshot)
                // 面板按鼠标所在屏幕显示，不能假定它总在主屏；每次显示前重取。
                let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
                large = PanelMetrics.previewLargeSize(screenSize: screen?.frame.size ?? NSSize(width: 1800, height: 1169))
                panel.show()
                await panel.debugSettle()
                // 合成事件没有真实键盘事件前的布局周期，先让卡片锚点可用。
                panel.debugForceLayout()
                panel.debugPress(keyCode: 49, characters: " ")
                await panel.debugSettle()
                panel.debugForceLayout()
                defer { panel.hide() }
                if let shots { panel.debugSnapshot(to: shots, name: "preview-\(shotIndex)"); shotIndex += 1 }
                return panel.debugPreviewSize
            }
            let previewCases: [(String, ClipSnapshot)] = [
                ("单个文件", fileClip([note])),
                ("已不存在的文件", fileClip([directory.appendingPathComponent("gone.pdf")])),
                ("多个文件", fileClip([note, directory.appendingPathComponent("gone.pdf")])),
                ("内网链接", ClipSnapshot(items: [ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.plainText, data: Data("http://192.168.1.1/admin".utf8))])])),
            ]
            // 三种链接卡片：有配图、只有站点图标、什么都没取到。
            for (url, metadata) in [
                ("https://example.com/with-image", PasteCore.LinkMetadata(title: "有配图的页面标题，比较长需要截断", image: makeTextPNG("COVER"), imageKind: .image)),
                ("https://example.com/with-icon?query=a-rather-long-address-that-needs-truncation", PasteCore.LinkMetadata(title: "Icon Only", image: makeTextPNG("i"), imageKind: .icon)),
                ("https://example.com/nothing", PasteCore.LinkMetadata()),
            ] {
                try store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.plainText, data: Data(url.utf8))])]))
                if let job = try store.nextLinkAwaitingMetadata() { try store.setLinkMetadata(metadata, for: job) }
            }
            let linkCards = try store.clips(matching: ClipQuery(text: "example.com"), limit: 5)
            check("链接卡片的标题和配图类型已写入", linkCards.map(\.linkImage) == [.none, .icon, .image] && linkCards[1].linkTitle == "Icon Only")

            for (name, snapshot) in previewCases {
                let size = try await previewSize(of: snapshot)
                check("\(name)的预览是大浮层", size == large, "\(size.map { "\($0)" } ?? "未打开")，应为 \(large)")
            }

            // 3b. 图片预览：按空格时先按记录的像素数摆好浮层，原图在后台读出、解码后再放进来，不在主线程上读（L09）
            let imageClip = try store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [
                ClipRepresentation(type: ClipType.png, data: makeTextPNG("L09 preview"))])]))
            panel.show()
            await panel.debugSettle()
            panel.debugForceLayout()
            panel.debugPress(keyCode: 49, characters: " ")
            let awaitedImage = panel.debugPreviewAwaitsImage && !panel.debugPreviewShowsImage
            await panel.debugSettle()
            let imageOpened = panel.debugPreviewClipID == imageClip.id
            let imageShown = panel.debugPreviewShowsImage && !panel.debugPreviewAwaitsImage
            panel.hide()
            check("图片预览先摆好浮层，原图在后台解码后放入", imageOpened && awaitedImage && imageShown,
                  "打开 \(imageOpened) 按下时在等 \(awaitedImage) 之后已显示 \(imageShown)")

            // 3c. 编辑与新建：保存后位置和时间不变；没改动或取消不写库；新建排在最前
            func plain(_ string: String) -> ClipSnapshot {
                ClipSnapshot(items: [ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.plainText, data: Data(string.utf8))])])
            }
            let editor = panel.debugEditor
            let editTarget = try store.record(plain("待编辑的文本"))
            try store.record(plain("排在它前面的一条"))
            panel.show()
            await panel.debugSettle()
            panel.debugSelect(index: 1)
            await panel.debugSettle()
            panel.debugEditSelection()
            await panel.debugSettle()
            check("⌘E 打开 390 × 316 的编辑窗口，面板收起", editor.debugWindowSize == NSSize(width: 390, height: 316) && !panel.isVisible,
                  "\(editor.debugWindowSize.map { "\($0)" } ?? "未打开")")
            await editor.debugFinish(save: true)
            check("没有改动时保存不写库", try store.summary(id: editTarget.id) == editTarget)

            panel.show()
            await panel.debugSettle()
            panel.debugSelect(index: 1)
            await panel.debugSettle()
            panel.debugEditSelection()
            await panel.debugSettle()
            editor.debugTextView?.insertText("，已修改", replacementRange: NSRange(location: 6, length: 0))
            await editor.debugFinish(save: false)
            check("取消不写库", try store.summary(id: editTarget.id) == editTarget)

            panel.show()
            await panel.debugSettle()
            panel.debugSelect(index: 1)
            await panel.debugSettle()
            panel.debugEditSelection()
            await panel.debugSettle()
            editor.debugTextView?.insertText("，已修改", replacementRange: NSRange(location: 6, length: 0))
            await editor.debugFinish(save: true)
            let afterEdit = try store.clips(limit: 2)
            check("保存后内容更新，位置和时间不变", afterEdit[1].id == editTarget.id && afterEdit[1].previewText == "待编辑的文本，已修改"
                  && afterEdit[1].timestamp == editTarget.timestamp && !editor.isOpen, afterEdit[1].previewText)

            // 保存失败（写库抛错）：窗口留着、内容还在，改好后可以再保存（审查 15）。
            struct SaveFailure: Error {}
            var failNextSave = true
            var savedAfterRetry: EditorResult?
            editor.open(.newText, on: nil) { result in
                if failNextSave { failNextSave = false; throw SaveFailure() }
                savedAfterRetry = result
            }
            editor.debugTextView?.insertText("保存失败后重试", replacementRange: NSRange(location: 0, length: 0))
            await editor.debugFinish(save: true)
            let keptOpen = editor.isOpen && editor.debugTextView?.string == "保存失败后重试"
            await editor.debugFinish(save: true)
            check("编辑保存失败时窗口和内容留着，重试成功后关闭", keptOpen && !editor.isOpen && savedAfterRetry != nil)

            panel.show()
            await panel.debugSettle()
            panel.newTextItem()
            let newSize = editor.debugWindowSize
            editor.debugTextView?.insertText("新建的 bold 文本", replacementRange: NSRange(location: 0, length: 0))
            editor.debugTextView?.setSelectedRange(NSRange(location: 4, length: 4))
            editor.debugToggleBold()
            let boldButtonOn = editor.debugStyleStates == [true, false, false, false]
            editor.debugTextView?.setSelectedRange(NSRange(location: 1, length: 0))
            let boldButtonOff = editor.debugStyleStates == [false, false, false, false]
            check("格式按钮按选区和光标处的格式显示状态", boldButtonOn && boldButtonOff, "\(editor.debugStyleStates)")
            // 没有斜体样式的中文字体（Safari 复制来的苹方）：文字保持原样，底栏说明原因，按钮不亮。
            if let storage = editor.debugTextView?.textStorage, let pingFang = NSFont(name: "PingFangSC-Regular", size: 13) {
                storage.addAttribute(.font, value: pingFang, range: NSRange(location: 0, length: 3))
                editor.debugTextView?.setSelectedRange(NSRange(location: 0, length: 3))
                editor.debugToggleItalic()
                let unchanged = (storage.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)?.fontName == pingFang.fontName
                    && storage.attribute(.obliqueness, at: 1, effectiveRange: nil) == nil
                let notice = editor.debugFooterText
                check("没有斜体样式的字体：文字不变，底栏说明原因，斜体按钮不亮", unchanged && notice == "所选文字的字体没有斜体样式" && !editor.debugStyleStates[1],
                      "\(notice) 按钮 \(editor.debugStyleStates)")
            }
            await editor.debugFinish(save: true)
            let created = try store.clips(limit: 1)[0]
            let createdRTF = try store.snapshot(id: created.id)?.items.first?.data(for: ClipType.rtf)
            let boldRange = createdRTF.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) }.map { rich -> Bool in
                let font = rich.attribute(.font, at: 5, effectiveRange: nil) as? NSFont
                let plainFont = rich.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                return font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true
                    && plainFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == false
            }
            check("新文本项窗口 500 × 360，创建后排在最前", newSize == NSSize(width: 500, height: 360) && created.previewText == "新建的 bold 文本")
            check("加粗的那一段存进了富文本表示", boldRange == true)
            await panel.debugSettle()
            check("创建后重新显示面板并选中新条目", panel.isVisible && panel.debugSelectedID == created.id)

            // 带 RTF 的文本条目按富文本预览（原版如此，L05）：加粗那段在预览里仍是粗体，没写颜色的部分用跟随外观的文字色。
            panel.debugPress(keyCode: 49, characters: " ")
            await panel.debugSettle()
            let shown = panel.debugPreviewText
            let shownBold = shown.flatMap { $0.length > 5 ? $0.attribute(.font, at: 5, effectiveRange: nil) as? NSFont : nil }
                .map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true
            let shownColor = shown.flatMap { $0.length > 0 ? $0.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor : nil }
            check("带格式的文本按富文本预览", shown?.string == "新建的 bold 文本" && shownBold && shownColor == .labelColor,
                  "\(shown?.string ?? "未显示") 粗体 \(shownBold)")
            panel.hide()
            let sample = NSMutableAttributedString(string: "黑", attributes: [.foregroundColor: NSColor.black])
            sample.append(NSAttributedString(string: "红", attributes: [.foregroundColor: NSColor.systemRed]))
            let prepared = RichTextDisplay.prepare(sample, font: .systemFont(ofSize: 13))
            check("卡片按富文本显示：存了开头一段的富文本，写死的黑色改为跟随外观，彩色保留",
                  try store.summary(id: created.id)?.richPreview != nil
                  && prepared.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .labelColor
                  && prepared.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor == .systemRed)
            // 一次复制 1 万个文件（N07）：卡片、辅助功能名称都按全部路径算，面板仍要很快出来。
            let manyFiles = try store.record(ClipSnapshot(items: (0..<10_000).map {
                ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.fileURL, data: Data(URL(fileURLWithPath: "/tmp/xpaste-selftest-\($0).txt").absoluteString.utf8))])
            }))
            let filesStart = ContinuousClock.now
            panel.show()
            await panel.debugSettle()
            panel.debugForceLayout()
            let filesCard = panel.debugCardAccessibility(index: 0)
            let filesTime = ContinuousClock.now - filesStart
            check("1 万个文件的条目：面板显示和卡片的辅助功能名称在 0.5 秒内", filesCard?.label.hasPrefix("10,000 个文件") == true && filesTime < .milliseconds(500),
                  "\(filesTime) \(filesCard?.label.prefix(30) ?? "")")
            panel.hide()
            try store.removeFromHistory(ids: [manyFiles.id])

            // 一百万字符的文本（R06）：打开预览、切到下一张、再切回来，主线程都不能长时间卡住。
            let neighbour = try store.record(plain("下一条"))
            let million = (0..<20_000).map { "第 \($0) 行 " + String(repeating: "长文本内容", count: 9) }.joined(separator: "\n")
            let huge = try store.record(plain(million))
            panel.show()
            await panel.debugSettle()
            let openStart = ContinuousClock.now
            panel.debugPress(keyCode: 49, characters: " ")
            await panel.debugSettle()
            let openTime = ContinuousClock.now - openStart
            let hugeShown = panel.debugPreviewText?.length == million.utf16.count
            let switchStart = ContinuousClock.now
            panel.debugPress(keyCode: 124)
            await panel.debugSettle()
            panel.debugPress(keyCode: 123)
            await panel.debugSettle()
            let switchTime = ContinuousClock.now - switchStart
            check("一百万字符的文本：预览打开和来回切换都在 1 秒内", hugeShown && openTime < .seconds(1) && switchTime < .seconds(1),
                  "字符 \(million.utf16.count) 打开 \(openTime) 来回切换 \(switchTime)")
            panel.hide()
            try store.removeFromHistory(ids: [huge.id, neighbour.id])
            if let shots {
                panel.show()
                await panel.debugSettle()
                panel.debugForceLayout()
                panel.debugSnapshot(to: shots, name: "rich-card")
                panel.hide()
            }

            panel.show()
            await panel.debugSettle()
            panel.newTextItem()
            await editor.debugFinish(save: true)
            check("空的新文本项不创建", try store.clips(limit: 1)[0].id == created.id)

            // 面板开着时的局部更新（轻量化）：新复制、重新复制已有内容、改名，每次卡片都和数据对得上。
            panel.show()
            await panel.debugSettle()
            panel.debugForceLayout()
            let firstBefore = panel.debugVisiblePreviews.first
            try store.record(plain("局部更新 新复制"))
            panel.historyDidChange()
            await panel.debugSettle()
            panel.debugForceLayout()
            let insertedOK = panel.debugVisiblePreviews.prefix(2) == ["局部更新 新复制", firstBefore ?? ""][...] && panel.debugCardsMatchData
            if let older = try store.clips(limit: 5).last {
                try store.touch(id: older.id)
                try store.setTitle("局部更新 改名", for: older.id)
            }
            panel.historyDidChange()
            await panel.debugSettle()
            panel.debugForceLayout()
            check("面板开着时新复制、重新复制、改名都只局部更新，卡片和数据一致", insertedOK && panel.debugCardsMatchData,
                  "\(panel.debugVisiblePreviews.prefix(3))")
            panel.hide()


            let colorClip = try store.record(plain("#3366CC"))
            panel.show()
            await panel.debugSettle()
            panel.debugEditSelection()
            await panel.debugSettle()
            editor.debugPickColor("#112233")
            await editor.debugFinish(save: true)
            check("颜色编辑后色值更新，仍是颜色条目", try store.summary(id: colorClip.id).map { $0.previewText == "#112233" && $0.kind == .color } == true)

            let linkClip = try store.record(plain("http://192.168.1.1/old"))
            panel.show()
            await panel.debugSettle()
            panel.debugEditSelection()
            await panel.debugSettle()
            let linkSize = editor.debugWindowSize
            editor.debugTextView?.insertText("http://192.168.1.1/new", replacementRange: NSRange(location: 0, length: 22))
            await editor.debugFinish(save: true)
            let editedLink = try store.summary(id: linkClip.id)?.previewText
            check("链接编辑窗口 390 × 322，保存后地址更新", linkSize == NSSize(width: 390, height: 322) && editedLink == "http://192.168.1.1/new")

            // 3d. 图片编辑：旋转后宽高互换、位置不变、重新排队识别；有主体的图可以移除背景
            // 旋转保留原图的色彩空间和位深，写出的 PNG 带着色彩配置（L29）。
            func solidImage(space: CFString, bits: Int) -> CGImage? {
                let context = CGContext(data: nil, width: 6, height: 4, bitsPerComponent: bits, bytesPerRow: 0, space: CGColorSpace(name: space)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.setFillColor(CGColor(colorSpace: CGColorSpace(name: space)!, components: [1, 0, 0, 1])!)
                context?.fill(CGRect(x: 0, y: 0, width: 6, height: 4))
                return context?.makeImage()
            }
            let p3Turned = solidImage(space: CGColorSpace.displayP3, bits: 8).flatMap { ImageEditing.rotated($0, quarterTurns: 1) }
            let p3RoundTrip = p3Turned.flatMap(ImageEditing.png).flatMap(ImageEditing.decode)
            let deepTurned = solidImage(space: CGColorSpace.displayP3, bits: 16).flatMap { ImageEditing.rotated($0, quarterTurns: 1) }
            check("旋转保留色彩空间和位深，PNG 带色彩配置",
                  p3Turned?.colorSpace?.name == CGColorSpace.displayP3 && p3RoundTrip?.colorSpace?.name == CGColorSpace.displayP3
                  && p3RoundTrip?.width == 4 && deepTurned?.bitsPerComponent == 16,
                  "\(String(describing: p3RoundTrip?.colorSpace?.name)) \(deepTurned?.bitsPerComponent ?? 0) 位")
            let wide = try store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.png, data: makeTextPNG("ROTATE"))])]))
            if let job = try store.nextImageAwaitingOCR() { try store.setOCRResult("rotate me", for: job) }
            try store.record(plain("排在图片前面的一条"))
            panel.show()
            await panel.debugSettle()
            panel.debugSelect(index: 1)
            await panel.debugSettle()
            panel.debugEditSelection()
            await panel.debugSettle()
            let imageEditorSize = editor.debugWindowSize
            editor.debugRotateLeft()
            await editor.debugFinish(save: true)
            let turned = try store.clips(limit: 2)[1]
            check("图片编辑窗口 390 × 316，向左旋转保存后宽高互换、位置不变", imageEditorSize == NSSize(width: 390, height: 316) && turned.id == wide.id
                  && turned.pixelWidth == 240 && turned.pixelHeight == 640 && turned.timestamp == wide.timestamp,
                  "\(turned.pixelWidth ?? 0) × \(turned.pixelHeight ?? 0)")
            check("旋转后的图片重新排队识别，旧的识别文字不再可搜", try store.nextImageAwaitingOCR()?.id == wide.id
                  && (try store.clips(matching: ClipQuery(text: "rotate me"))).isEmpty)
            panel.show()
            await panel.debugSettle()
            panel.debugSelect(index: 1)
            await panel.debugSettle()
            panel.debugEditSelection()
            await panel.debugSettle()
            for _ in 0..<4 { editor.debugRotateLeft() }
            await editor.debugFinish(save: true)
            check("转满一圈等于没改，不写库", try store.summary(id: wide.id) == turned)

            // 用系统自带的一张动物头像测主体提取；这台机器上没有这张图就跳过。
            if let subject = NSImage(contentsOfFile: "/Library/User Pictures/Animals/Penguin.heic")?.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let subjectPNG = ImageEditing.png(subject) {
                let animal = try store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.png, data: subjectPNG)])]))
                panel.show()
                await panel.debugSettle()
                panel.debugEditSelection()
                await panel.debugSettle()
                for _ in 0..<100 where !editor.debugCanRemoveBackground { try? await Task.sleep(for: .milliseconds(100)) }
                check("识别到主体后可以移除背景", editor.debugCanRemoveBackground)
                editor.debugToggleBackground()
                await editor.debugFinish(save: true)
                let lifted = try store.imageData(id: animal.id).flatMap(ImageEditing.decode)
                let corner = lifted.flatMap { image -> UInt8? in
                    // 左上角是背景，移除后应该是透明的。
                    guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                    context.draw(image, in: CGRect(x: 0, y: -CGFloat(image.height - 1), width: CGFloat(image.width), height: CGFloat(image.height)))
                    return context.data?.load(fromByteOffset: 3, as: UInt8.self)
                }
                check("移除背景后尺寸不变，背景处变透明", lifted?.width == subject.width && lifted?.height == subject.height && corner == 0,
                      "左上角不透明度 \(corner.map(String.init) ?? "读不到")")
            } else {
                print("INFO 没有系统自带的测试图，跳过主体提取")
            }

            // 筛选浮层的键盘操作（照原版）：方向键移动焦点，回车选中焦点所在的项并收起浮层，字母不进搜索框。
            panel.show()
            await panel.debugSettle()
            panel.debugToggleFilter()
            let filter = panel.debugFilterPanel
            let insets = filter.debugChipInsets
            check("筛选浮层里选项离左右两边一样远", abs(insets.left - insets.right) < 1 && insets.left > 10, "左 \(insets.left) 右 \(insets.right)")
            let swallowedLetter = filter.debugPress(keyCode: 0, characters: "a")
            _ = filter.debugPress(keyCode: 125)
            let firstFocus = filter.debugFocusedIndex
            _ = filter.debugPress(keyCode: 124)
            let secondFocus = filter.debugFocusedIndex
            _ = filter.debugPress(keyCode: 36)
            check("筛选浮层：↓ 落到第一项，→ 到第二项，回车选中“图片”并收起",
                  swallowedLetter && firstFocus == 0 && secondFocus == 1 && panel.debugFilter.kinds == [.image] && !filter.isVisible,
                  "字母吞掉 \(swallowedLetter) 焦点 \(String(describing: firstFocus)) → \(String(describing: secondFocus)) 条件 \(panel.debugFilter.kinds) 浮层 \(filter.isVisible)")
            // 鼠标点选也是选中后立即收起、回到搜索框（原版如此）。
            panel.debugToggleFilter()
            filter.debugClick(index: 0)
            check("筛选浮层：点选“未知”后收起，焦点回到搜索框",
                  !filter.isVisible && panel.debugFilter.kinds == [.unknown, .image] && panel.debugSearchFocused,
                  "浮层 \(filter.isVisible) 条件 \(panel.debugFilter.kinds) 搜索框焦点 \(panel.debugSearchFocused)")
            // 退格：第一次只选中最后一个标记（“图片”），第二次才删掉。
            panel.debugSearchBackspace()
            let selectedFirst = panel.debugLastTokenSelected, kindsAfterFirst = panel.debugFilter.kinds
            panel.debugSearchBackspace()
            check("搜索框退格：先选中最后一个标记，再按一次才删除",
                  selectedFirst && kindsAfterFirst == [.unknown, .image] && panel.debugFilter.kinds == [.unknown] && !panel.debugLastTokenSelected,
                  "第一次选中 \(selectedFirst) 条件 \(kindsAfterFirst) → \(panel.debugFilter.kinds)")
            panel.hide()

            // 3e. 多选：⇧ 扩选、回缩、⌘A；批量粘贴按显示顺序交出；批量删除先确认，撤销时一起回来
            // 各隔 10 ms：时间戳只精确到毫秒，同一毫秒写入的几条按 id 排序，撤销删除重新插入后先后会变（L95）。
            let multiBase = Date()
            for (offset, name) in ["多选 D", "多选 C", "多选 B", "多选 A"].enumerated() {
                try store.record(plain(name), now: multiBase.addingTimeInterval(Double(offset) * 0.01))
            }
            var pasted: [[String]] = []
            panel.onPaste = { clips, _, _, _ in pasted.append(clips.map(\.previewText)) }
            panel.show()
            await panel.debugSettle()
            panel.debugPress(keyCode: 124)
            await panel.debugSettle()
            check("→ 之后集合视图里只有一条选中", panel.debugCollectionSelection == [1], "\(panel.debugCollectionSelection)")
            panel.debugPress(keyCode: 124, modifiers: .shift)
            await panel.debugSettle()
            panel.debugPress(keyCode: 124, modifiers: .shift)
            await panel.debugSettle()
            check("⇧→ 两次选中三条", panel.debugSelectedPreviews == ["多选 B", "多选 C", "多选 D"], "\(panel.debugSelectedPreviews)")
            panel.debugPress(keyCode: 123, modifiers: .shift)
            await panel.debugSettle()
            check("⇧← 回缩一条", panel.debugSelectedPreviews == ["多选 B", "多选 C"])
            if let b = panel.debugVisiblePreviews.firstIndex(of: "多选 B"), let c = panel.debugVisiblePreviews.firstIndex(of: "多选 C") {
                let dragged = panel.debugDragPasteboard(at: c)
                let first = dragged.first, second = dragged.dropFirst().first
                check("多选拖动：合并文本只在第一个 item 上，其余只带条目 ID",
                      first?.string(forType: .string) == "多选 B\n多选 C\n" && first?.data(forType: .rtf) != nil
                      && second?.string(forType: .string) == nil && second?.string(forType: ClipDrag.idsType) != nil,
                      "\(first?.string(forType: .string) ?? "nil") / \(second?.string(forType: .string) ?? "nil")")
            }
            check("⇧← 回缩后集合视图里的选中一致", panel.debugCollectionSelection == [1, 2], "\(panel.debugCollectionSelection)")
            // 鼠标手势（卡片拖拽闪烁与偶发起拖失败）：按在多选组里先保留整组，确认是单击才收拢；按到未选中的立即选中；
            // 按住期间的后台刷新延后到松手；双击在第二次松手、仍是同一条时才粘贴。
            if let b = panel.debugVisiblePreviews.firstIndex(of: "多选 B"), let c = panel.debugVisiblePreviews.firstIndex(of: "多选 C"),
               let a = panel.debugVisiblePreviews.firstIndex(of: "多选 A") {
                panel.debugMouse(.leftMouseDown, index: c)
                let keptGroup = panel.debugSelectedPreviews
                panel.debugMouse(.leftMouseDragged, index: c, offset: PanelController.dragThreshold - 1)
                let stillPressed = panel.debugCardPressed
                panel.debugMouse(.leftMouseUp, index: c)
                check("按在多选组里先保留整组，阈值内移动不起拖，松手后收拢成这一条",
                      keptGroup == ["多选 B", "多选 C"] && stillPressed && panel.debugSelectedPreviews == ["多选 C"] && !panel.debugCardPressed,
                      "按下 \(keptGroup) 仍按住 \(stillPressed) 松手 \(panel.debugSelectedPreviews)")
                panel.debugMouse(.leftMouseDown, index: b, modifiers: .command)
                panel.debugMouse(.leftMouseUp, index: b, modifiers: .command)
                check("⌘ 点按加入多选", panel.debugSelectedPreviews == ["多选 B", "多选 C"], "\(panel.debugSelectedPreviews)")
                panel.debugMouse(.leftMouseDown, index: a)
                let selectedOnDown = panel.debugSelectedPreviews
                panel.historyDidChange()
                let deferred = panel.debugPendingBackgroundReload
                panel.debugMouse(.leftMouseUp, index: a)
                check("按到未选中的卡片立即选中；按住期间的后台刷新延后到松手",
                      selectedOnDown == ["多选 A"] && deferred && !panel.debugPendingBackgroundReload,
                      "按下 \(selectedOnDown) 延后 \(deferred) 松手后 \(panel.debugPendingBackgroundReload)")
                await panel.debugSettle()
                // 第二次松手落在别的卡片上不算双击。
                panel.debugMouse(.leftMouseDown, index: a)
                panel.debugMouse(.leftMouseUp, index: a)
                panel.debugMouse(.leftMouseDown, index: a, clickCount: 2)
                panel.debugMouse(.leftMouseUp, index: b, clickCount: 2)
                try? await Task.sleep(for: .milliseconds(50))
                check("双击时第二次松手不在同一张卡片上，不粘贴", pasted.isEmpty && panel.isVisible, "\(pasted)")
                // 恢复成 B、C 两条、当前是 C，后面的检查接着用。
                panel.debugMouse(.leftMouseDown, index: b)
                panel.debugMouse(.leftMouseUp, index: b)
                panel.debugMouse(.leftMouseDown, index: c, modifiers: .command)
                panel.debugMouse(.leftMouseUp, index: c, modifiers: .command)
                check("恢复成两条多选", panel.debugSelectedPreviews == ["多选 B", "多选 C"] && panel.debugCollectionSelection == [b, c].sorted(),
                      "\(panel.debugSelectedPreviews) \(panel.debugCollectionSelection)")
            }
            // 辅助功能：整张卡片是一个元素，名称里有类型和内容，带选中状态和常用操作；焦点在当前那张（选中的最后一条）上。
            let card = panel.debugCardAccessibility(index: 2)
            check("卡片在辅助功能里是一个带名称、状态和操作的元素",
                  card.map { $0.label.hasPrefix("文本，") && $0.label.contains("多选 C") && $0.selected && $0.children == 0 && $0.focused
                      && $0.actions == ["以纯文本粘贴", "复制", "预览", "编辑", "删除"] } == true, "\(String(describing: card))")
            check("未选中的卡片不报已选中", panel.debugCardAccessibility(index: 0)?.selected == false)
            panel.debugPress(keyCode: 36)
            await panel.debugSettle()
            for _ in 0..<200 where pasted.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
            check("回车把选中的两条按显示顺序交给回放，面板收起", pasted == [["多选 B", "多选 C"]] && !panel.isVisible, "\(pasted)")
            // 双击一张卡片：只粘贴这一张（按“粘贴项目”的设置），面板收起。
            pasted = []
            panel.show()
            await panel.debugSettle()
            if let c = panel.debugVisiblePreviews.firstIndex(of: "多选 C") {
                panel.debugMouse(.leftMouseDown, index: c)
                panel.debugMouse(.leftMouseUp, index: c)
                panel.debugMouse(.leftMouseDown, index: c, clickCount: 2)
                let pastedOnDown = !pasted.isEmpty || !panel.isVisible
                panel.debugMouse(.leftMouseUp, index: c, clickCount: 2)
                for _ in 0..<200 where pasted.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
                check("双击在第二次松手时才粘贴", !pastedOnDown)
            }
            check("双击卡片把这一张交给回放，面板收起", pasted == [["多选 C"]] && !panel.isVisible, "\(pasted)")
            // 提示卡片和历史卡片一起横向滚动（原版如此）。没有提示时（已授权、已开登录项）跳过。
            panel.show()
            await panel.debugSettle()
            let before = panel.debugTipAndFirstCardFrames
            if let tip = before.tips.first, let card = before.card {
                let clip = panel.debugScrollView.contentView
                clip.scroll(to: NSPoint(x: 60, y: 0))
                panel.debugScrollView.reflectScrolledClipView(clip)
                let after = panel.debugTipAndFirstCardFrames
                check("提示卡片在第一张卡片左边，和卡片一起滚动",
                      tip.maxX < card.minX && abs((after.tips.first?.minX ?? 0) - (tip.minX - 60)) < 1 && abs((after.card?.minX ?? 0) - (card.minX - 60)) < 1,
                      "提示 \(tip) 卡片 \(card) 滚动后 \(String(describing: after.tips.first)) \(String(describing: after.card))")
                clip.scroll(to: .zero)
                panel.debugScrollView.reflectScrolledClipView(clip)
                // 提示容器是面板长期持有的同一个视图，不是分区头；第一张卡片不会被提示盖住（L141）。
                check("集合视图里只有一个提示容器，第一张卡片中心命中卡片自己",
                      panel.debugTipContainerCount == 1 && panel.debugFirstCardHitIsCard, "容器 \(panel.debugTipContainerCount)")
                // × 只关本次显示：历史卡片在同一次布局里前移；下次打开面板，条件仍成立的提示回来。
                let shown = panel.debugDisplayedTips
                let width = tip.width
                panel.debugCloseTip(shown[0])
                await panel.debugSettle()
                let closed = panel.debugTipAndFirstCardFrames
                let gap = panel.debugTipSpacing
                check("点 × 后这张提示消失，历史卡片前移一张提示的位置，第一张仍能点中",
                      panel.debugDisplayedTips == Array(shown.dropFirst()) && abs((closed.card?.minX ?? 0) - (card.minX - width - gap)) < 1
                          && panel.debugFirstCardHitIsCard && panel.debugTipContainerCount == 1,
                      "提示 \(panel.debugDisplayedTips) 卡片 \(String(describing: closed.card)) 原 \(card)")
                panel.hide()
                await panel.debugSettle()
                panel.show()
                await panel.debugSettle()
                let reopened = panel.debugTipAndFirstCardFrames
                check("下次打开面板时被 × 关掉的提示重新出现，卡片回到原位",
                      panel.debugDisplayedTips == shown && abs((reopened.card?.minX ?? 0) - card.minX) < 1 && panel.debugFirstCardHitIsCard,
                      "提示 \(panel.debugDisplayedTips) 卡片 \(String(describing: reopened.card))")
            } else {
                print("INFO 没有显示提示卡片，跳过提示随卡片滚动的检查")
            }
            panel.hide()

            panel.show()
            await panel.debugSettle()
            panel.debugPress(keyCode: 124)
            await panel.debugSettle()
            panel.debugPress(keyCode: 124, modifiers: .shift)
            await panel.debugSettle()
            var asked: [Int] = []
            panel.confirmBatchDelete = { count, _ in asked.append(count); return false }
            panel.debugPress(keyCode: 51)
            await panel.debugSettle()
            let leftAfterCancel = try store.clips(matching: ClipQuery(text: "多选")).count
            check("批量删除先确认，取消则不删", asked == [2] && panel.debugSelectedCount == 2 && leftAfterCancel == 4)
            panel.confirmBatchDelete = { count, _ in asked.append(count); return true }
            panel.debugPress(keyCode: 51)
            await panel.debugSettle()
            check("确认后两条一起删除，选中落到后面那一条", try store.clips(matching: ClipQuery(text: "多选")).map(\.previewText) == ["多选 A", "多选 D"]
                  && panel.debugSelectedPreviews == ["多选 D"], "\(panel.debugSelectedPreviews)")
            panel.debugPress(keyCode: 6, modifiers: .command)
            await panel.debugSettle()
            let restoredOrder = try store.clips(limit: 4).map(\.previewText)
            check("⌘Z 把两条一起恢复到原位", restoredOrder == ["多选 A", "多选 B", "多选 C", "多选 D"], "\(restoredOrder)")

            // 一次删除太多时不留撤销副本，确认框说明无法撤销（L102）。
            for index in 0..<201 { _ = try store.record(plain("批量撤销 \(index)")) }
            panel.debugSearch("批量撤销")
            await panel.debugSettle()
            panel.debugPress(keyCode: 0, characters: "a", modifiers: .command)
            await panel.debugSettle()
            var undoableAnswer: Bool?
            let undoDepth = panel.debugUndoDepth
            panel.confirmBatchDelete = { _, undoable in undoableAnswer = undoable; return true }
            panel.debugPress(keyCode: 51)
            await panel.debugSettle()
            let bulkLeft = try store.clips(matching: ClipQuery(text: "批量撤销"), limit: 300).count
            check("一次删除 201 条时确认框说明无法撤销，不留撤销副本", undoableAnswer == false && panel.debugUndoDepth == undoDepth && bulkLeft == 0,
                  "\(String(describing: undoableAnswer)) 剩 \(bulkLeft)")
            panel.debugSearch("")
            await panel.debugSettle()
            panel.debugPress(keyCode: 51)
            await panel.debugSettle()
            check("单条删除不确认", asked.count == 2)
            panel.debugPress(keyCode: 6, modifiers: .command)
            await panel.debugSettle()
            panel.debugPress(keyCode: 0, characters: "a", modifiers: .command)
            await panel.debugSettle()
            let historyCount = try store.clipIDs().count
            check("⌘A 选中整个历史", panel.debugSelectedCount == historyCount && historyCount > panel.debugLoadedCount,
                  "选中 \(panel.debugSelectedCount) 共 \(historyCount)")
            panel.debugPress(keyCode: 124)
            await panel.debugSettle()
            check("不按 ⇧ 移动后回到单选", panel.debugSelectedCount == 1)

            // ⌘A 选中整个列表，包括还没加载的（L33）：60 条超过一页 50 条。
            for index in 0..<60 { try store.record(plain("全选 \(index)")) }
            panel.debugSearch("全选")
            await panel.debugSettle()
            let loadedBefore = panel.debugLoadedCount
            panel.debugPress(keyCode: 0, characters: "a", modifiers: .command)
            await panel.debugSettle()
            check("⌘A 选中整个列表，含未加载的条目", loadedBefore == 50 && panel.debugSelectedCount == 60 && panel.debugSelectedClipCount == 60,
                  "已加载 \(loadedBefore) 选中 \(panel.debugSelectedCount) 取到 \(panel.debugSelectedClipCount)")
            // ⌘A 后拖出（审查 08）：拖动项和合并文本覆盖同样的 60 条，含没加载的 10 条。
            let draggedAll = panel.debugDragPasteboard(at: 0)
            let draggedIDs = draggedAll.compactMap { $0.string(forType: ClipDrag.idsType) }
            let draggedLines = draggedAll.first?.string(forType: .string)?.split(separator: "\n") ?? []
            check("⌘A 后拖出：拖动项和合并文本都是完整的 60 条", draggedIDs.count == 60 && Set(draggedIDs).count == 60 && draggedLines.count == 60,
                  "拖动项 \(draggedIDs.count) 文本行 \(draggedLines.count)")
            panel.debugPress(keyCode: 124)
            await panel.debugSettle()
            check("整表选中后移动回到单选", panel.debugSelectedCount == 1 && panel.debugSelectedClipCount == 1)
            panel.debugSearch("")
            await panel.debugSettle()
            panel.hide()
            panel.onPaste = nil

            // 3f. Pinboard 里拖动排序的落点处理；面板内部拖动用的私有类型能读回条目 ID
            let board = try store.createPinboard(name: "排序", colorHex: "#4B8DF7")
            let pinned = try ["排序 1", "排序 2", "排序 3"].map { try store.record(plain($0)).id }
            try store.pin(ids: pinned, to: board.id)
            panel.show()
            await panel.debugSettle()
            panel.debugSelect(scope: .pinboard(board.id))
            await panel.debugSettle()
            let movedOK = panel.debugReorder(ids: [pinned[2]], before: 0)
            await panel.debugSettle()
            check("把第三条拖到最前，列表按新顺序显示", movedOK && panel.debugVisiblePreviews == ["排序 3", "排序 1", "排序 2"], "\(panel.debugVisiblePreviews)")
            // 横向一排时系统给的落点是 0×0，竖线不会出现；每个落点都要在相邻两张卡片之间（L36）。
            let drop = panel.debugDropGaps
            let gapsOK = drop.items.count == 3 && drop.gaps.count == 4 && drop.gaps.allSatisfy { $0.width > 0 && $0.height > 0 }
                && (1..<3).allSatisfy { abs(drop.gaps[$0].minX - drop.items[$0 - 1].maxX) < 1 && abs(drop.gaps[$0].maxX - drop.items[$0].minX) < 1 }
                && abs(drop.gaps[3].minX - drop.items[2].maxX) < 1
            check("Pinboard 排序的落点竖线在相邻卡片之间", gapsOK, "\(drop.gaps)")
            panel.debugSelect(scope: .history)
            await panel.debugSettle()
            panel.hide()

            // 页签多到放不下时横向滚动（L50）：不压到“更多”按钮，选中的页签滚进可见范围。
            let manyBoards = try (1...25).map { try store.createPinboard(name: "很长的页签名称 \($0)", colorHex: "#4B8DF7") }
            panel.show()
            await panel.debugSettle()
            if let last = manyBoards.last { panel.debugSelect(scope: .pinboard(last.id)) }
            await panel.debugSettle()
            try? await Task.sleep(for: .milliseconds(100))
            let tabsLayout = panel.debugToolbar.debugTabsLayout
            let centerFrame = panel.debugToolbar.debugCenterFrame, moreFrame = panel.debugToolbar.debugMoreButtonFrame
            check("页签放不下时可横向滚动，不压到更多按钮，选中的页签可见",
                  tabsLayout.content > tabsLayout.visible && tabsLayout.visible > 100 && centerFrame.maxX <= moreFrame.minX && tabsLayout.selectedVisible,
                  "可见 \(tabsLayout.visible) 全部 \(tabsLayout.content) 选中可见 \(tabsLayout.selectedVisible)")
            if let shots {
                panel.debugForceLayout()
                panel.debugSnapshot(to: shots, name: "many-tabs")
            }
            panel.debugSelect(scope: .history)
            await panel.debugSettle()
            panel.hide()
            for board in manyBoards { try store.deletePinboard(id: board.id) }
            let dragBoard = NSPasteboard(name: NSPasteboard.Name("xpaste-selftest-drag"))
            dragBoard.clearContents()
            dragBoard.setString("12,7,12,x,3", forType: ClipDrag.idsType)
            check("拖动用的私有类型读回条目 ID，去重并忽略无效值", ClipDrag.ids(from: dragBoard) == [12, 7, 3])
            dragBoard.releaseGlobally()
            try store.deletePinboard(id: board.id)

            // 3f2. 面板高度：拖动时光标上方显示高度、不吸附，双击上缘恢复默认，锁定后拖不动也不还原、锁挂在右上角（偏好测完还原）
            let heightPrefs = panel.debugPreferences
            let savedHeight = heightPrefs.panelHeight
            let savedLock = heightPrefs.panelHeightLocked
            heightPrefs.panelHeightLocked = false
            panel.show()
            await panel.debugSettle()
            let defaultHeight = PanelMetrics.windowHeight
            check("默认高度 332，卡片边长 234", defaultHeight == 332 && PanelMetrics.cardSide(windowHeight: defaultHeight) == 234)
            let heightBefore = panel.debugPanelHeight
            panel.debugDragHeight(by: 380 - heightBefore, ended: false)
            check("拖动上缘到 380，光标上方显示当前高度", panel.debugPanelHeight == 380 && panel.debugWindowHeight == 380
                  && panel.debugHeightTip == ("380 pt", true), "\(panel.debugPanelHeight) \(panel.debugHeightTip)")
            panel.debugDragHeight(by: defaultHeight + 4 - heightBefore, ended: false)
            check("经过默认高度附近不吸附", panel.debugPanelHeight == defaultHeight + 4, "\(panel.debugPanelHeight)")
            panel.debugDragHeight(by: 380 - heightBefore, ended: true)
            check("松手后记住高度", panel.debugPanelHeight == 380 && heightPrefs.panelHeight == 380)
            check("指针不在上缘时没有柔光", !panel.debugEdgeGlowLit)
            panel.debugHoverEdge(true)
            check("没锁定、指针移到上缘时面板上方亮起柔光", panel.debugEdgeGlowLit)
            panel.togglePanelHeightLock()
            check("指针还在上缘时锁定，柔光马上熄灭", !panel.debugEdgeGlowLit)
            panel.debugHoverEdge(false)
            panel.debugHoverEdge(true)
            check("锁定时指针移到上缘不亮", !panel.debugEdgeGlowLit)
            panel.togglePanelHeightLock()
            check("指针在上缘时解锁，柔光亮起", panel.debugEdgeGlowLit)
            panel.debugHoverEdge(false)
            check("指针离开后柔光熄灭", !panel.debugEdgeGlowLit)
            check("不在默认高度时右键菜单可以恢复默认", panel.debugHeightMenu.map(\.title) == ["锁定面板高度", "恢复默认高度（332 pt）"]
                  && panel.debugHeightMenu[1].enabled && !panel.debugHeightMenu[0].on, "\(panel.debugHeightMenu)")
            check("“…”菜单里没有关于和帮助，有面板高度两项", !panel.debugMoreMenuTitles.contains("关于 XPaste") && !panel.debugMoreMenuTitles.contains("XPaste 帮助"),
                  "\(panel.debugMoreMenuTitles)")
            panel.debugDoubleClickHeightHandle()
            let resetStart = ContinuousClock.now
            while panel.debugHeightAnimating, ContinuousClock.now - resetStart < .seconds(1) { try? await Task.sleep(for: .milliseconds(20)) }
            check("双击上缘缓动回默认高度并记住", panel.debugPanelHeight == defaultHeight && panel.debugWindowHeight == defaultHeight
                  && heightPrefs.panelHeight == Double(defaultHeight), "\(panel.debugPanelHeight)")
            check("已经是默认高度时恢复默认置灰", !panel.debugHeightMenu[1].enabled)
            panel.debugDragHeight(by: 360 - defaultHeight, ended: true)
            check("没锁时右上角没有锁", !panel.debugLockBadgeVisible)
            panel.togglePanelHeightLock()
            panel.debugDragHeight(by: 40, ended: false)
            panel.debugDragHeight(by: 40, ended: true)
            panel.debugDoubleClickHeightHandle()
            try? await Task.sleep(for: .milliseconds(50))
            check("锁定后拖动和双击都不改高度，锁挂在右上角，菜单打勾、恢复默认置灰", panel.debugPanelHeight == 360 && heightPrefs.panelHeightLocked
                  && panel.debugLockBadgeVisible && panel.debugHeightMenu[0].on && !panel.debugHeightMenu[1].enabled,
                  "\(panel.debugPanelHeight) \(panel.debugHeightMenu)")
            panel.debugClickLockBadge()
            check("点右上角的锁就解锁，锁消失", !heightPrefs.panelHeightLocked && !panel.debugLockBadgeVisible && panel.debugHeightMenu[1].enabled)
            panel.hide()
            heightPrefs.panelHeightLocked = savedLock
            heightPrefs.panelHeight = savedHeight

            // 3f3. 文本预览尺寸按排版量（原版 6.6.2）：短文本 390 × 316；长文本宽高各到屏幕一半为止
            let previewScreen = NSSize(width: 1800, height: 1169)
            func textPreview(_ text: String) -> NSSize {
                PanelMetrics.previewSize(forContent: PanelMetrics.previewTextContentSize(PreviewContent.displayText(text, rich: nil), screenSize: previewScreen))
            }
            // 量尺寸只取开头 2000 个码元：每行 75 个字（排开约 975 点，超过一半屏宽要折行），2000 字里约 26 行、折成 50 多行，高过屏幕一半。
            let longLine = String(repeating: "很长的一行文字", count: 11) + "结尾"
            let longText = Array(repeating: longLine, count: 100).joined(separator: "\n")
            let longSize = textPreview(longText)
            let mediumText = Array(repeating: "第几行", count: 20).joined(separator: "\n")
            let mediumSize = textPreview(mediumText)
            check("文本预览：短文本 390 × 316", textPreview("你好") == NSSize(width: 390, height: 316), "\(textPreview("你好"))")
            check("文本预览：长文本宽高都到屏幕一半为止（高 661，宽接近 910）", longSize.height == 661 && longSize.width > 880 && longSize.width <= 910, "\(longSize)")
            check("文本预览：行多但不宽的文本只增高", mediumSize.width == 390 && mediumSize.height > 316 && mediumSize.height < 661, "\(mediumSize)")

            // 3g. Stack：后复制的先粘，反转后先复制的先粘；长按不重复推进；粘完最后一项自动关闭
            let stackBoard = NSPasteboard(name: NSPasteboard.Name("xpaste-selftest-stack"))
            stackBoard.clearContents()
            var acknowledged = 0
            let stack = StackController(store: store, pasteboard: stackBoard, interceptsPaste: false) { _ in acknowledged += 1 }
            stack.open()
            let emptyHeight = stack.debugWindowHeight ?? 0
            check("Stack 空窗口放得下标题栏和一行说明", emptyHeight >= StackController.headerHeight + StackListView.minRowHeight, "\(emptyHeight)")
            // 方向记在偏好里，测完恢复成原来的。
            let wasReversed = stack.debugIsReversed
            if wasReversed { stack.debugFlipDirection() }
            for name in ["栈 1", "栈 2", "栈 3", "栈 4"] {
                let snapshot = plain(name)
                stack.collect(snapshot, summary: try store.record(snapshot))
            }
            check("收集四条后最新的在最上面，窗口随行数变高", stack.debugTitles == ["栈 4", "栈 3", "栈 2", "栈 1"]
                  && (stack.debugWindowHeight ?? 0) > emptyHeight + 3 * StackListView.minRowHeight, "\(stack.debugTitles) \(stack.debugWindowHeight ?? 0)")
            let firstSwallowed = stack.debugPressPaste()
            check("第一次 ⌘V 写出最新的一条并放行按键", !firstSwallowed && stackBoard.string(forType: .string) == "栈 4" && stack.debugTitles == ["栈 3", "栈 2", "栈 1"])
            let repeatSwallowed = stack.debugPressPaste(isRepeat: true)
            check("长按的重复按键被吞掉，队列不推进", repeatSwallowed && stack.debugTitles == ["栈 3", "栈 2", "栈 1"] && stackBoard.string(forType: .string) == "栈 4")
            stack.debugFlipDirection()
            // 时间只精确到毫秒，同一毫秒的按 id 排（L95）；真实按键之间远不止 10 ms。
            try? await Task.sleep(for: .milliseconds(10))
            _ = stack.debugPressPaste()
            check("反转后写出最早的一条", stackBoard.string(forType: .string) == "栈 1" && stack.debugTitles == ["栈 2", "栈 3"], "\(stack.debugTitles)")
            try? await Task.sleep(for: .milliseconds(10))
            _ = stack.debugPressPaste()
            try? await Task.sleep(for: .milliseconds(10))
            _ = stack.debugPressPaste()
            try? await Task.sleep(for: .milliseconds(50))
            check("粘完最后一项后窗口自动关闭，每次写入都通知了监听器", !stack.isOpen && stackBoard.string(forType: .string) == "栈 3" && acknowledged == 4, "acknowledged=\(acknowledged)")
            // 写库在后台：最多等 2 秒，不靠固定等待（L146）。
            let touchStart = ContinuousClock.now
            while (try? store.clips(limit: 1).first?.previewText) != "栈 3", ContinuousClock.now - touchStart < .seconds(2) {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let stackOrder = try store.clips(limit: 4).map(\.previewText)
            check("粘过的条目回到历史最前，顺序和粘贴顺序一致", stackOrder == ["栈 3", "栈 2", "栈 1", "栈 4"], "\(stackOrder)")
            check("关闭后的 ⌘V 原样放行", !stack.debugPressPaste())
            // 排在 Stack 里的条目中途被删：内容照样粘得出，但不会因此回到历史里（R22）
            stack.open()
            let doomed = plain("stackdoomed 9417")
            let doomedClip = try store.record(doomed)
            stack.collect(doomed, summary: doomedClip)
            try store.removeFromHistory(ids: [doomedClip.id])
            _ = stack.debugPressPaste()
            try? await Task.sleep(for: .milliseconds(50))
            let revived = try store.clips(matching: ClipQuery(text: "stackdoomed"), limit: 5)
            check("Stack 里的条目被删除后粘出，不回到历史", stackBoard.string(forType: .string) == "stackdoomed 9417" && revived.isEmpty)

            // 3g2. Stack 改版（Docs/归档/验收记录/Stack改版.md）：从面板加入、排序、插队、删除与撤销、全部粘贴、纯文本、行内容
            let wasPlain = AppPreferences.shared.stackPastePlainText
            AppPreferences.shared.stackPastePlainText = false
            // 上一段测完停在反转状态；这一段从默认方向（新的放最上面）开始。
            if stack.debugIsReversed { stack.debugFlipDirection() }
            let picked = try ["甲", "乙", "丙"].map { try store.record(plain("改版 \($0)")) }
            stack.add(picked)
            check("从面板加入按面板顺序排，Stack 随之打开", stack.isOpen && stack.debugTitles == ["改版 甲", "改版 乙", "改版 丙"], "\(stack.debugTitles)")
            let copiedLater = plain("改版 丁")
            stack.collect(copiedLater, summary: try store.record(copiedLater))
            check("之后复制的放最上面", stack.debugTitles == ["改版 丁", "改版 甲", "改版 乙", "改版 丙"], "\(stack.debugTitles)")
            stack.move(uid: stack.debugUIDs[0], to: 3)
            check("拖动排序：最上面一行挪到最下面", stack.debugTitles == ["改版 甲", "改版 乙", "改版 丙", "改版 丁"], "\(stack.debugTitles)")
            check("没有可撤销的操作时不显示撤销", !stack.debugUndoVisible)
            stack.pasteOutOfTurn(uid: stack.debugUIDs[1])
            check("双击插队：写出这一行，它离开 Stack，撤销出现", stackBoard.string(forType: .string) == "改版 乙"
                  && stack.debugTitles == ["改版 甲", "改版 丙", "改版 丁"] && stack.debugUndoVisible, "\(stack.debugTitles)")
            stack.remove(uid: stack.debugUIDs[0])
            check("× 删除一行", stack.debugTitles == ["改版 丙", "改版 丁"])
            stack.undo()
            stack.undo()
            check("撤销两次，两行都回到原来的位置，撤销消失", stack.debugTitles == ["改版 甲", "改版 乙", "改版 丙", "改版 丁"] && !stack.debugUndoVisible,
                  "\(stack.debugTitles)")
            // ⌘V 逐项粘出的也能撤销（原版视频 00:19）
            _ = stack.debugPressPaste()
            try? await Task.sleep(for: .milliseconds(30))
            let afterPasteUndo = stack.debugUndoVisible
            stack.undo()
            check("⌘V 粘出最上面一行后出现撤销，撤销放回最上面", afterPasteUndo && stack.debugTitles == ["改版 甲", "改版 乙", "改版 丙", "改版 丁"]
                  && !stack.debugUndoVisible, "\(stack.debugTitles)")
            // × 压在卡片右上角，有一半露在卡片外面（原版视频 00:16、00:18）
            let stackList = stack.debugList
            let removeFrame = stackList.debugHover(row: 1) ?? .zero
            let hoveredRow = stackList.debugRowFrames[1]
            check("× 叠在指针所在那一行的右上角", removeFrame.maxX > hoveredRow.maxX && removeFrame.midX < hoveredRow.maxX
                  && removeFrame.minY < hoveredRow.minY && removeFrame.midY > hoveredRow.minY, "× \(removeFrame) 行 \(hoveredRow)")
            let hoverRemove = stackList.debugHoverRemoveButton()
            check("指针移到 × 上它换样子", hoverRemove.hovering)
            stackList.debugClickRemove()
            check("点 × 移除的是这一行", stack.debugTitles == ["改版 甲", "改版 丙", "改版 丁"], "\(stack.debugTitles)")
            stack.undo()
            // 拖出一行：对方收下就离开 Stack；取消、没放下、按了 Esc 都留在原处并冒云团
            let draggedUID = stack.debugUIDs[1]
            let cancelPoof = stackList.debugEndDrag(uid: draggedUID, operation: [])
            let escapePoof = stackList.debugEndDrag(uid: draggedUID, operation: .copy, escaped: true)
            check("拖出取消或按 Esc：这一行留在原处，冒云团", cancelPoof && escapePoof
                  && stack.debugTitles == ["改版 甲", "改版 乙", "改版 丙", "改版 丁"] && !stack.debugUndoVisible, "\(stack.debugTitles)")
            let acceptedPoof = stackList.debugEndDrag(uid: draggedUID, operation: .copy)
            check("拖出被别的应用收下：这一行离开 Stack，不冒云团，可以撤销", !acceptedPoof
                  && stack.debugTitles == ["改版 甲", "改版 丙", "改版 丁"] && stack.debugUndoVisible, "\(stack.debugTitles)")
            stack.undo()
            check("“…”菜单有全部粘贴、反转顺序、以纯文本粘贴", stack.debugMenuTitles().filter { !$0.isEmpty } == ["全部粘贴", "反转顺序", "以纯文本粘贴"],
                  "\(stack.debugMenuTitles())")
            let stackPicture = try store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [
                ClipRepresentation(type: ClipType.png, data: makeTextPNG("STACK"))])]))
            stack.add([stackPicture])
            check("图片行写类型名，右侧有缩略图", stack.debugRowTexts.first == ClipCardItem.typeTitle(for: stackPicture)
                  && stack.debugRowHasCover == [true, false, false, false, false], "\(stack.debugRowTexts) \(stack.debugRowHasCover)")
            // 要看窗口的样子时（XPASTE_SELFTEST_STACK_HOLD=秒数），停在这里，由外面按窗口编号截图。
            if let hold = ProcessInfo.processInfo.environment["XPASTE_SELFTEST_STACK_HOLD"].flatMap(Double.init) {
                print("STACKWINDOW \(stack.debugWindowNumber ?? 0)")
                if let shots {
                    stack.debugSnapshot(to: shots.appendingPathComponent("stack-light.png"), appearance: NSAppearance(named: .aqua))
                    stack.debugSnapshot(to: shots.appendingPathComponent("stack-dark.png"), appearance: NSAppearance(named: .darkAqua))
                }
                fflush(stdout)
                try? await Task.sleep(for: .seconds(hold))
            }
            stack.pasteAll()
            check("全部粘贴：文本项按顺序每项一行一次写出、末尾不带换行，图片留下", stackBoard.string(forType: .string) == "改版 甲\n改版 乙\n改版 丙\n改版 丁"
                  && stack.debugTitles.count == 1 && stack.debugUndoVisible, "\(stackBoard.string(forType: .string) ?? "") \(stack.debugTitles)")
            if let shots = ProcessInfo.processInfo.environment["XPASTE_SELFTEST_SHOTS"].map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
                stack.debugSnapshot(to: shots.appendingPathComponent("stack-undo.png"), appearance: NSAppearance(named: .darkAqua))
            }
            stack.undo()
            check("撤销全部粘贴，文本项回到原位", stack.debugTitles.count == 5 && stack.debugTitles.suffix(4) == ["改版 甲", "改版 乙", "改版 丙", "改版 丁"],
                  "\(stack.debugTitles)")
            stack.debugFlipDirection()
            check("反转顺序整列翻过来", stack.debugTitles.prefix(4) == ["改版 丁", "改版 丙", "改版 乙", "改版 甲"], "\(stack.debugTitles)")
            stack.close()
            // 文件行：加进来时在后台检查文件；能访问的文件按 ⌘V 照常写出文件地址（用户真机：文件粘不出来）
            let stackFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("xpaste-stack-\(UUID().uuidString).txt")
            try Data("stack file".utf8).write(to: stackFileURL)
            let stackFile = ClipSnapshot(items: [ClipItemSnapshot(representations: [
                ClipRepresentation(type: ClipType.fileURL, data: Data(stackFileURL.absoluteString.utf8))])])
            stack.add([try store.record(stackFile)])
            let fileCheckStart = ContinuousClock.now
            while stack.debugFileAccess(row: 0) == nil, ContinuousClock.now - fileCheckStart < .seconds(2) { try? await Task.sleep(for: .milliseconds(20)) }
            check("文件行加进来就检查过文件，能用", stack.debugFileAccess(row: 0)?.isUsable == true)
            _ = stack.debugPressPaste()
            let pastedFiles = (stackBoard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
            check("文件行按 ⌘V 写出文件地址", pastedFiles.map(\.standardizedFileURL) == [stackFileURL.standardizedFileURL], "\(pastedFiles)")
            try? FileManager.default.removeItem(at: stackFileURL)
            try? await Task.sleep(for: .milliseconds(50))
            stack.close()
            // 带格式的文本：行里按富文本显示；打开“以纯文本粘贴”后只写出文本
            let styled = NSAttributedString(string: "改版 粗体", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
            let styledRTF = try styled.data(from: NSRange(location: 0, length: styled.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            let styledClip = try store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [
                ClipRepresentation(type: ClipType.plainText, data: Data("改版 粗体".utf8)), ClipRepresentation(type: ClipType.rtf, data: styledRTF)])]))
            stack.add([styledClip, picked[0]])
            AppPreferences.shared.stackPastePlainText = true
            _ = stack.debugPressPaste()
            check("以纯文本粘贴：只写出文本，不带 RTF", stackBoard.string(forType: .string) == "改版 粗体" && stackBoard.data(forType: .rtf) == nil)
            AppPreferences.shared.stackPastePlainText = false
            _ = stack.debugPressPaste()
            try? await Task.sleep(for: .milliseconds(50))
            check("粘完最后一项照旧关闭", !stack.isOpen)
            AppPreferences.shared.stackPastePlainText = wasPlain
            if stack.debugIsReversed != wasReversed { stack.debugFlipDirection() }
            stackBoard.releaseGlobally()

            // 3h. 音效：关着时不创建任何声音；开着时同一种不叠加；播完释放
            var soundOn = false
            let effects = SoundEffects { soundOn }
            effects.volume = 0
            effects.play(.copy)
            effects.play(.paste)
            check("音效关闭时不创建声音", effects.debugCreatedCount == 0 && effects.debugPlayingCount == 0)
            let wavesOK = SoundEffects.Effect.allCases.allSatisfy { effect in
                // 两个声音文件都打进了应用，能解码，时长不超过 0.5 秒。
                guard let data = SoundEffects.soundData(for: effect), let sound = NSSound(data: data) else { return false }
                return sound.duration > 0.03 && sound.duration < 0.5
            }
            check("两个提示音是有效的短音", wavesOK)

            // 图片卡片的棋盘格改成图案填充后（轻量化），方格仍从视图左上角开始：左上第一格是深的那种颜色，右边一格是底色。
            let checkerboard = CardCheckerboardView(frame: NSRect(x: 0, y: 0, width: 40, height: 24))
            checkerboard.appearance = NSAppearance(named: .darkAqua)
            let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 60, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
            // 默认关闭时自己释放一次，加上作用域结束时 Swift 的释放就多放了一次，偶发崩溃（2026-11-24 查明）。
            host.isReleasedWhenClosed = false
            host.contentView?.addSubview(checkerboard)
            checkerboard.setFrameOrigin(NSPoint(x: 7, y: 5))
            var boardPixels: [Int] = []
            if let rep = checkerboard.bitmapImageRepForCachingDisplay(in: checkerboard.bounds) {
                checkerboard.cacheDisplay(in: checkerboard.bounds, to: rep)
                let scale = CGFloat(rep.pixelsWide) / checkerboard.bounds.width
                for point in [NSPoint(x: 2, y: 2), NSPoint(x: 10, y: 2), NSPoint(x: 10, y: 10), NSPoint(x: 2, y: 10)] {
                    let color = rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.deviceGray)
                    boardPixels.append(Int(((color?.whiteComponent ?? 0) * 255).rounded()))
                }
            }
            host.close()
            check("棋盘格图案从卡片左上角开始", boardPixels.count == 4 && boardPixels[0] == boardPixels[2] && boardPixels[1] == boardPixels[3]
                  && boardPixels[0] > boardPixels[1], "\(boardPixels)")

            // 用到时才建、关掉就放的窗口（轻量化）：关闭后控制器和窗口都被释放，下次再要是新的一个。
            let helpWindows = OnDemandWindow { HelpWindowController(preferences: preferences) }
            weak var firstHelp = helpWindows.controller
            firstHelp?.window?.orderFront(nil)
            firstHelp?.close()
            try? await Task.sleep(for: .milliseconds(100))
            let released = helpWindows.current == nil && firstHelp == nil
            let reopened = helpWindows.controller
            check("帮助窗口关闭后释放，再打开是新建的", released && reopened.window != nil, "释放 \(released)")
            reopened.close()

            // 屏幕布局变化后的窗口位置（审查 09）：大半跑到屏幕外的窗口挪回来，放不下就缩小；还在屏幕里的不动。
            let visibleArea = NSRect(x: 0, y: 0, width: 1440, height: 875)
            let offscreen = NSRect(x: 2000, y: 300, width: 640, height: 592)
            let movedBack = WindowPlacement.clamped(offscreen, to: visibleArea)
            let tooBig = WindowPlacement.clamped(NSRect(x: -100, y: -100, width: 2000, height: 1200), to: visibleArea)
            check("屏幕变化后窗口挪回可用区域", !WindowPlacement.isUsable(offscreen, in: visibleArea) && visibleArea.contains(movedBack)
                  && movedBack.size == offscreen.size && tooBig == visibleArea
                  && WindowPlacement.isUsable(NSRect(x: 100, y: 100, width: 640, height: 592), in: visibleArea), "\(movedBack)")

            // 检查更新：版本号按数字逐段比较；没有配置仓库时不发请求，提示还没有发布。
            let versionsOK = UpdateChecker.isNewer("0.10.0", than: "0.9.2") && UpdateChecker.isNewer("1.0", than: "0.9.9")
                && !UpdateChecker.isNewer("0.1.0", than: "0.1") && !UpdateChecker.isNewer("0.1.0-beta", than: "0.1.0")
                && UpdateChecker.isNewer("0.1.1", than: "0.1.0")
            check("检查更新的版本比较", versionsOK)
            check("没有配置仓库时检查更新不联网", await UpdateChecker.check(repository: nil) == .notPublished)
            // 帮助窗口能排出来，快捷键按当前设置显示。
            let help = NSHostingView(rootView: HelpView(preferences: preferences))
            help.frame = NSRect(x: 0, y: 0, width: 560, height: 640)
            help.layoutSubtreeIfNeeded()
            check("帮助窗口能排版", help.fittingSize.height > 100, "\(help.fittingSize)")
            soundOn = true
            let threadsIdle = threadCount()
            for _ in 0..<100 {
                effects.play(.copy)
                effects.play(.paste)
            }
            let threadsBusy = threadCount()
            check("连续 100 次请求，每种只有一个声音在播", effects.debugCreatedCount == 2 && effects.debugPlayingCount == 2,
                  "创建 \(effects.debugCreatedCount) 在播 \(effects.debugPlayingCount)")
            // 播放结束的回调来自系统音频线程，机器忙时会晚到；最多等 3 秒，不靠固定等待（L83）。
            let releaseStart = ContinuousClock.now
            while effects.debugPlayingCount > 0, ContinuousClock.now - releaseStart < .seconds(3) {
                try? await Task.sleep(for: .milliseconds(20))
            }
            check("播完后声音对象已释放", effects.debugPlayingCount == 0, "用时 \(ContinuousClock.now - releaseStart)")
            try? await Task.sleep(for: .seconds(4))
            print("INFO 音效前后的线程数：空闲 \(threadsIdle)，播放中 \(threadsBusy)，播完 5 秒后 \(threadCount())")

            // 3i. 本机起一个只计连接数的监听端口，确认预览和取链接信息都不会碰本机地址（R24），带脚本的 HTML 不被执行（R25）
            let hits = HitCounter()
            let listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { connection in
                hits.value += 1
                connection.cancel()
            }
            listener.stateUpdateHandler = { if case .ready = $0 { hits.isReady = true } }
            listener.start(queue: .main)
            for _ in 0..<100 where !hits.isReady { try? await Task.sleep(for: .milliseconds(20)) }
            if hits.isReady, let port = listener.port?.rawValue, port != 0 {
                let control = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
                control.start(queue: .main)
                try? await Task.sleep(for: .milliseconds(300))
                control.cancel()
                check("监听端口能数到连接（对照）", hits.value == 1, "\(hits.value)")
                hits.value = 0

                for host in ["127.0.0.1", "localhost"] {
                    _ = try? await LinkMetadataFetcher.fetch(URL(string: "http://\(host):\(port)/once")!)
                }
                try store.record(plain("http://127.0.0.1:\(port)/once"))
                let links = LinkIndexer(store: store) { try await LinkMetadataFetcher.fetch($0) }
                await links.kick()
                let localLinkSize = try await previewSize(of: plain("http://localhost:\(port)/once"))
                try? await Task.sleep(for: .milliseconds(1_000))
                check("本机地址的链接：取页面信息和预览都没有发请求", hits.value == 0 && localLinkSize == large, "连接数 \(hits.value)，预览尺寸 \(String(describing: localLinkSize))，应为 \(large)")

                // 跳转到本机地址（L11）：放行第一跳去一个只会回 302 的本机服务，它把请求跳到计数端口；计数端口不应收到连接。
                let redirects = HitCounter()
                let redirector = try NWListener(using: .tcp, on: .any)
                redirector.newConnectionHandler = { connection in
                    redirects.value += 1
                    connection.start(queue: .main)
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                        let reply = "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(port)/redirected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    }
                }
                redirector.stateUpdateHandler = { if case .ready = $0 { redirects.isReady = true } }
                redirector.start(queue: .main)
                for _ in 0..<100 where !redirects.isReady { try? await Task.sleep(for: .milliseconds(20)) }
                if let redirectPort = redirector.port?.rawValue, let first = URL(string: "http://127.0.0.1:\(redirectPort)/start") {
                    LinkMetadataFetcher.debugAllowedFirstHop = first
                    let fetched = try? await LinkMetadataFetcher.fetch(first)
                    LinkMetadataFetcher.debugAllowedFirstHop = nil
                    try? await Task.sleep(for: .milliseconds(300))
                    check("取页面信息时跳转到本机地址被拦下", redirects.value == 1 && hits.value == 0 && fetched == nil,
                          "跳转服务 \(redirects.value) 次，计数端口 \(hits.value) 次")
                }
                redirector.cancel()

                // 检查时是公网、连接时被换成本机地址（DNS rebinding，L100）：放行事先检查去一个会正常回页面的本机服务，
                // 看实际连上的地址后应丢掉结果。
                let rebound = HitCounter()
                let pageServer = try NWListener(using: .tcp, on: .any)
                pageServer.newConnectionHandler = { connection in
                    rebound.value += 1
                    connection.start(queue: .main)
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                        let body = "<html><head><title>内网页面</title></head></html>"
                        let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                        connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    }
                }
                pageServer.stateUpdateHandler = { if case .ready = $0 { rebound.isReady = true } }
                pageServer.start(queue: .main)
                for _ in 0..<100 where !rebound.isReady { try? await Task.sleep(for: .milliseconds(20)) }
                if let pagePort = pageServer.port?.rawValue, let page = URL(string: "http://127.0.0.1:\(pagePort)/page") {
                    LinkMetadataFetcher.debugAllowedFirstHop = page
                    let fetched = try? await LinkMetadataFetcher.fetch(page)
                    LinkMetadataFetcher.debugAllowedFirstHop = nil
                    check("取页面信息时实际连上本机地址，结果被丢掉", rebound.value == 1 && fetched == nil,
                          "本机服务 \(rebound.value) 次，标题 \(fetched?.title ?? "无")")
                }
                pageServer.cancel()

                // 网页预览里的子资源（L11）：装上拦截规则后，页面里指向本机地址的图片不发请求；不装规则作对照。
                let webRules: WKContentRuleList? = await withCheckedContinuation { continuation in
                    PreviewWebRules.withPrivateAddressRules { continuation.resume(returning: $0) }
                }
                func subresourceHits(withRules: Bool) async -> Int {
                    hits.value = 0
                    let configuration = WKWebViewConfiguration()
                    configuration.websiteDataStore = .nonPersistent()
                    if withRules, let webRules { configuration.userContentController.add(webRules) }
                    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
                    web.loadHTMLString("<img src=\"http://127.0.0.1:\(port)/a\"><img src=\"http://localhost:\(port)/b\">", baseURL: URL(string: "http://example.com/"))
                    try? await Task.sleep(for: .milliseconds(1_500))
                    web.stopLoading()
                    return hits.value
                }
                let blockedHits = await subresourceHits(withRules: true)
                let controlHits = await subresourceHits(withRules: false)
                hits.value = 0
                check("网页预览里指向本机地址的子资源被拦下", webRules != nil && blockedHits == 0 && controlHits > 0,
                      "装规则 \(blockedHits) 次，对照 \(controlHits) 次")

                let html = Data("<html><body><script>new Image().src='http://127.0.0.1:\(port)/script'</script><img src=\"http://127.0.0.1:\(port)/img\">selftest html</body></html>".utf8)
                let htmlSnapshot = ClipSnapshot(items: [ClipItemSnapshot(representations: [
                    ClipRepresentation(type: ClipType.plainText, data: Data("selftest html".utf8)), ClipRepresentation(type: ClipType.html, data: html)])])
                let htmlClip = try store.record(htmlSnapshot)
                panel.show()
                await panel.debugSettle()
                panel.debugPress(keyCode: 49, characters: " ")
                await panel.debugSettle()
                panel.debugForceLayout()
                try? await Task.sleep(for: .milliseconds(1_000))
                let htmlPreviewed = panel.debugPreviewClipID == htmlClip.id
                // L146 现场：失败时看选中的、预览的、列表最前面几条是什么。
                let htmlScene = "选中 \(String(describing: panel.debugSelectedID)) 预览 \(String(describing: panel.debugPreviewClipID)) 应为 \(htmlClip.id) 可见 \(panel.isVisible) 前几条 \(panel.debugVisiblePreviews.prefix(3))"
                panel.hide()
                let storedHTML = try store.snapshot(id: htmlClip.id)?.items.first?.representations.first { $0.type == ClipType.html }?.data
                check("带脚本和远程图片的 HTML：预览时不执行、不请求，原始数据不变", htmlPreviewed && hits.value == 0 && storedHTML == html, "连接数 \(hits.value) \(htmlScene)")
            } else {
                check("监听端口已就绪", false)
            }
            listener.cancel()

            // 3j. 文件已不存在：回放前的检查认得出来，不把路径当成还能读的文件（R29）
            let access = await FileAccess.check([note, directory.appendingPathComponent("gone.pdf")])
            check("回放前检查出已不存在的文件", access.missing.map(\.lastPathComponent) == ["gone.pdf"] && access.denied.isEmpty && !access.isUsable)

            // 4. 图片文字识别：真实的 Vision 识别结果进搜索索引；预览尺寸规则
            let textImage = try store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [
                ClipRepresentation(type: ClipType.png, data: makeTextPNG("XPaste Selftest 4821\n季度报告"))])]))
            let pending = try store.nextImageAwaitingOCR()
            check("新图片排在识别队列最前", pending?.id == textImage.id)
            if let pending, let data = try store.imageData(id: pending.id) {
                let recognized = try await TextRecognition.recognize(data)
                try store.setOCRResult(recognized, for: pending)
                let hits = try store.clips(matching: ClipQuery(text: "4821"), limit: 5).map(\.id)
                let hitsChinese = try store.clips(matching: ClipQuery(text: "季度报告"), limit: 5).map(\.id)
                check("识别出的英文和数字可搜索", hits.contains(textImage.id), "识别结果：\(recognized.replacingOccurrences(of: "\n", with: " / "))")
                check("识别出的中文可搜索", hitsChinese.contains(textImage.id))
            }
            let screen = NSSize(width: 1800, height: 1169)
            func visible(_ w: CGFloat, _ h: CGFloat) -> NSSize {
                PanelMetrics.previewSize(forContent: PanelMetrics.previewImageContentSize(pixelSize: NSSize(width: w, height: h), screenSize: screen))
            }
            // 五组都是原版实测的 AX frame 减去四周各 13 的阴影边距。
            let sizesOK = visible(3000, 2000) == NSSize(width: 887, height: 661) && visible(800, 600) == NSSize(width: 790, height: 661)
                && visible(100, 80) == NSSize(width: 390, height: 316) && visible(300, 1200) == NSSize(width: 390, height: 661)
                && visible(1200, 300) == NSSize(width: 910, height: 316)
            check("图片预览尺寸与原版实测一致", sizesOK, "\(visible(3000, 2000)) \(visible(800, 600)) \(visible(1200, 300))")

            // 来源应用不在本机时用存下的图标，不退回通用图标（L42）。
            try store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.plainText, data: Data("卸载的应用".utf8))])],
                                          sourceBundleID: "com.example.uninstalled-app", sourceName: "Gone"))
            let iconPNG = AppAppearanceCache.png(of: NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil) ?? NSImage(), side: 128) ?? Data()
            try store.setAppIconIfMissing(bundleID: "com.example.uninstalled-app", png: iconPNG)
            let cacheBefore = (AppAppearanceCache.shared.storedIcon, AppAppearanceCache.shared.onIconAvailable)
            AppAppearanceCache.shared.storedIcon = { try? store.appIcon(bundleID: $0) }
            AppAppearanceCache.shared.debugForget("com.example.uninstalled-app")
            let goneIcon = AppAppearanceCache.shared.appearance(for: "com.example.uninstalled-app").icon
            check("已卸载应用的卡片用存下的图标", goneIcon.map { Int($0.size.width) } == 128)
            AppAppearanceCache.shared.debugForget("com.example.uninstalled-app")
            (AppAppearanceCache.shared.storedIcon, AppAppearanceCache.shared.onIconAvailable) = cacheBefore

            // 没有鲜艳颜色的系统应用各有各的灰，排在一起分得开；亮度不超过 0.6，白字看得清（L96）。
            let neutralApps = ["com.apple.Terminal", "com.apple.TextEdit", "com.apple.calculator", "com.apple.ScriptEditor2"]
            let neutralColors = neutralApps.compactMap { id -> NSColor? in
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
                return NSWorkspace.shared.icon(forFile: url.path).dominantColor.usingColorSpace(.sRGB)
            }
            let neutralDistinct = neutralColors.indices.allSatisfy { i in
                neutralColors.indices.allSatisfy { j in
                    let a = neutralColors[i], b = neutralColors[j]
                    let distance = abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
                    return i == j || distance * 255 >= 12
                }
            }
            check("无彩色图标的应用各有自己的灰", neutralColors.count >= 2 && neutralDistinct && neutralColors.allSatisfy { $0.brightnessComponent <= 0.61 },
                  neutralColors.compactMap(\.hexString).joined(separator: " "))

            // 图片另存成文件附上地址（L32、L34）：PNG 原样写，TIFF 转成 PNG；已有文件地址的不动。
            let tiffImage = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
            let pngData = makeTextPNG("FILE")
            let withFiles = ImageFiles.attachingFiles(to: ClipSnapshot(items: [
                ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.png, data: pngData)]),
                ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.tiff, data: tiffImage.tiffRepresentation ?? Data())]),
            ]), name: "预览")
            let written = withFiles.fileURLs
            let filesOK = written.count == 2 && written.allSatisfy { $0.path.hasPrefix(ImageFiles.folder.path) && $0.pathExtension == "png" }
                && (try? Data(contentsOf: written[0])) == pngData
                && written.last.flatMap { NSImage(contentsOf: $0) } != nil
                && written[0].lastPathComponent.hasPrefix("预览 ")
            let untouched = ImageFiles.attachingFiles(to: withFiles, name: "预览").fileURLs == written
            check("图片另存成临时 PNG 并附上文件地址", filesOK && untouched, written.map(\.lastPathComponent).joined(separator: ", "))
            written.forEach { try? FileManager.default.removeItem(at: $0) }

            // 5. 反复开关后资源数量不增长。分三批各 1000 次：第一批用来预热缓存，比较后两批之间的增长。
            func cycle(_ times: Int) async {
                for i in 0..<times {
                    autoreleasepool { panel.show(); panel.hide() }
                    // 让出主线程，临时对象和窗口服务器的回调才有机会处理。
                    if i % 25 == 24 { try? await Task.sleep(for: .milliseconds(5)) }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            await cycle(1_000)
            let windowsBefore = NSApp.windows.count
            let memory1 = footprint()
            await cycle(1_000)
            let memory2 = footprint()
            await cycle(1_000)
            let memory3 = footprint()
            let windowsAfter = NSApp.windows.count
            check("开关 2000 次后窗口数不变", windowsAfter == windowsBefore, "\(windowsBefore) → \(windowsAfter)")
            check("没有残留的刷新定时器", !panel.debugHasRefreshTimer)
            check("面板已隐藏且不保留列表数据", !panel.isVisible && panel.debugLoadedCount == 0, "isVisible=\(panel.isVisible) 已加载=\(panel.debugLoadedCount)")
            func mb(_ bytes: Int64) -> String { String(format: "%.1f", Double(bytes) / 1_048_576) }
            let growth = Double(memory3 - memory2) / 1_048_576
            check("第 3 个 1000 次的内存增长 < 5 MB", growth < 5, "三批后分别为 \(mb(memory1)) / \(mb(memory2)) / \(mb(memory3)) MB")
        } catch {
            check("自检过程无异常", false, "\(error)")
        }
        print(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILED (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }

    private static func makeTextPNG(_ text: String) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 240, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 640, height: 240).fill()
        (text as NSString).draw(in: NSRect(x: 20, y: 20, width: 600, height: 200),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 48, weight: .medium), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    private static func makePNG() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    /// 当前进程的线程数。
    private static func threadCount() -> Int {
        var threads: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return 0 }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
        return Int(count)
    }

    /// 进程的物理内存占用（phys_footprint）。
    private static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}
/// 监听端口收到的连接数。只在主队列上读写。
private final class HitCounter: @unchecked Sendable {
    var value = 0
    var isReady = false
}
#endif
