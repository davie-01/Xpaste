import AppKit
import Carbon.HIToolbox
import Testing
@testable import ClipboardKit

private func rep(_ type: String, _ string: String) -> ClipRepresentation {
    ClipRepresentation(type: type, data: Data(string.utf8))
}

private func textItem(_ string: String) -> ClipItemSnapshot {
    ClipItemSnapshot(representations: [rep(ClipType.plainText, string)])
}

@Suite struct ClassifierTests {
    @Test func kinds() {
        #expect(ClipClassifier.kind(of: [textItem("hello world")]) == .text)
        #expect(ClipClassifier.kind(of: [textItem("https://example.com/a?b=1")]) == .link)
        #expect(ClipClassifier.kind(of: [textItem("see https://example.com")]) == .text)
        #expect(ClipClassifier.kind(of: [textItem("#BCFF0A")]) == .color)
        #expect(ClipClassifier.kind(of: [textItem("ff5500")]) == .color)
        for notColor in ["#FFF", "#FF550080", "rgb(255, 85, 0)", "red", "0xFF5500", "#notcolor"] {
            #expect(ClipClassifier.kind(of: [textItem(notColor)]) == .text)
        }
        #expect(ClipClassifier.kind(of: [ClipItemSnapshot(representations: [rep(ClipType.png, "x")])]) == .image)
        #expect(ClipClassifier.kind(of: [ClipItemSnapshot(representations: [
            rep(ClipType.fileURL, "file:///tmp/a.txt"), rep(ClipType.plainText, "a.txt"),
        ])]) == .file)
        #expect(ClipClassifier.kind(of: []) == .unknown)
    }
}

@Suite struct FingerprintTests {
    @Test func ignoresRepresentationOrderWithinItem() {
        let a = ClipSnapshot(items: [ClipItemSnapshot(representations: [rep(ClipType.plainText, "x"), rep(ClipType.rtf, "y")])])
        let b = ClipSnapshot(items: [ClipItemSnapshot(representations: [rep(ClipType.rtf, "y"), rep(ClipType.plainText, "x")])])
        #expect(a.fingerprint == b.fingerprint)
    }

    @Test func distinguishesItemOrderAndFormat() {
        let ab = ClipSnapshot(items: [textItem("a"), textItem("b")])
        let ba = ClipSnapshot(items: [textItem("b"), textItem("a")])
        #expect(ab.fingerprint != ba.fingerprint)

        // 文本相同但富文本不同，不能合并。
        let plain = ClipSnapshot(items: [textItem("x")])
        let rich = ClipSnapshot(items: [ClipItemSnapshot(representations: [rep(ClipType.plainText, "x"), rep(ClipType.rtf, "y")])])
        #expect(plain.fingerprint != rich.fingerprint)
    }

    @Test func itemBoundaryMatters() {
        let one = ClipSnapshot(items: [ClipItemSnapshot(representations: [rep(ClipType.plainText, "a"), rep(ClipType.rtf, "b")])])
        let two = ClipSnapshot(items: [textItem("a"), ClipItemSnapshot(representations: [rep(ClipType.rtf, "b")])])
        #expect(one.fingerprint != two.fingerprint)
    }
}

@Suite struct PolicyTests {
    @Test func disabledFiltersStillBlockOwnWrites() {
        var policy = CapturePolicy()
        policy.ignoreConfidential = false
        policy.ignoreTransient = false
        #expect(policy.decide(types: ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"], sourceBundleID: nil) == .capture)
        #expect(policy.decide(types: [CapturePolicy.selfMarker], sourceBundleID: nil) == .skip(.ownWrite))
    }

    @Test func markers() {
        var policy = CapturePolicy()
        policy.ignoredBundleIDs = ["com.example.secret"]
        #expect(policy.decide(types: [ClipType.plainText], sourceBundleID: nil) == .capture)
        #expect(policy.decide(types: [ClipType.plainText, "org.nspasteboard.ConcealedType"], sourceBundleID: nil) == .skip(.confidential))
        #expect(policy.decide(types: [ClipType.plainText, "org.nspasteboard.TransientType"], sourceBundleID: nil) == .skip(.transient))
        #expect(policy.decide(types: [ClipType.plainText, CapturePolicy.selfMarker], sourceBundleID: nil) == .skip(.ownWrite))
        #expect(policy.decide(types: [ClipType.plainText], sourceBundleID: "com.example.secret") == .skip(.ignoredApp))

        policy.ignoreConfidential = false
        #expect(policy.decide(types: ["org.nspasteboard.ConcealedType"], sourceBundleID: nil) == .capture)
    }
}

@MainActor
@Suite struct PasteboardRoundTripTests {
    let pasteboard = NSPasteboard.withUniqueName()
    let source = ClipSource(bundleID: "com.example.app", name: "Example")

    private func read(_ policy: CapturePolicy = CapturePolicy()) -> PasteboardReadResult {
        PasteboardReader.read(from: pasteboard, policy: policy, source: source)
    }

    @Test func multiRepresentationItemIsOneItem() throws {
        let item = NSPasteboardItem()
        item.setString("hello", forType: .string)
        item.setData(Data("{\\rtf1 hello}".utf8), forType: .rtf)
        item.setData(Data("ignored".utf8), forType: .init("com.apple.webarchive"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        guard case .snapshot(let snapshot) = read() else { Issue.record("expected snapshot"); return }
        #expect(snapshot.items.count == 1)
        #expect(Set(snapshot.items[0].representations.map(\.type)) == [ClipType.plainText, ClipType.rtf])
        #expect(snapshot.kind == .text)
        #expect(snapshot.sourceBundleID == "com.example.app")
    }

    @Test func declaredSourceWinsOverFrontmostApp() throws {
        func write(declared: String?) {
            let item = NSPasteboardItem()
            item.setString("from a background tool", forType: .string)
            if let declared { item.setString(declared, forType: .init("org.nspasteboard.source")) }
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
        }
        write(declared: "com.apple.finder")
        guard case .snapshot(let declared) = read() else { Issue.record("expected snapshot"); return }
        #expect(declared.sourceBundleID == "com.apple.finder" && declared.sourceName?.isEmpty == false)
        // 自报的来源也用于忽略应用的判断。
        var policy = CapturePolicy()
        policy.ignoredBundleIDs = ["com.apple.finder"]
        #expect(read(policy) == .skipped(.ignoredApp))
        // 空值表示不透露，仍用前台应用；不在本机的应用名称用 bundle ID。
        write(declared: "")
        guard case .snapshot(let blank) = read() else { Issue.record("expected snapshot"); return }
        #expect(blank.sourceBundleID == "com.example.app")
        write(declared: "com.example.not-installed")
        guard case .snapshot(let missing) = read() else { Issue.record("expected snapshot"); return }
        #expect(missing.sourceName == "com.example.not-installed")
    }

    @Test func multipleFilesKeepCountAndOrder() {
        let urls = ["file:///tmp/a.txt", "file:///tmp/b.txt", "file:///tmp/c.txt"]
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { url in
            let item = NSPasteboardItem()
            item.setString(url, forType: .fileURL)
            return item
        })

        guard case .snapshot(let snapshot) = read() else { Issue.record("expected snapshot"); return }
        #expect(snapshot.kind == .file)
        #expect(snapshot.fileURLs.map(\.absoluteString) == urls)

        // 回放后仍是三个 item，顺序不变。
        PasteboardWriter.write(snapshot, to: pasteboard)
        #expect(pasteboard.pasteboardItems?.compactMap { $0.string(forType: .fileURL) } == urls)
    }

    /// 系统没接受写入时返回 nil，调用方据此不显示“已复制”、不发 ⌘V（审查 01）。
    @Test @MainActor func failedWriteReturnsNil() {
        let board = NSPasteboard(name: .init("xpaste-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let snapshot = ClipSnapshot(items: [ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.plainText, data: Data("x".utf8))])])
        #expect(PasteboardWriter.write(snapshot, to: board) != nil)
        PasteboardWriter.debugFailWrites = true
        defer { PasteboardWriter.debugFailWrites = false }
        #expect(PasteboardWriter.write(snapshot, to: board) == nil)
        #expect(PasteboardWriter.write(ClipSnapshot(items: []), to: board) == nil)
    }

    /// HTML 转纯文本不走 WebKit（审查 GH-03）：断行、表格、实体、外部图片都不需要加载。
    @Test func htmlToPlainTextWithoutWebKit() {
        let html = """
        <html><head><style>p{color:red}</style><script>alert(1)</script></head><body>
        <h1>标题</h1><p>第一段 &amp; <b>粗体</b>&nbsp;文字<br>换行</p>
        <img src="http://10.255.255.1/slow.png"><!-- 注释 -->
        <table><tr><td>A</td><td>B</td></tr><tr><td>1</td><td>2</td></tr></table>
        <p>&#x4E2D;&#25991; &lt;tag&gt; &unknown; R&D</p></body></html>
        """
        let started = ContinuousClock.now
        let text = HTMLText.plainText(from: Data(html.utf8))
        #expect(ContinuousClock.now - started < .milliseconds(200))
        #expect(text == "标题\n第一段 & 粗体 文字\n换行\nA\tB\n1\t2\n\n中文 <tag> &unknown; R&D")
    }

    /// 多文件里去掉不能用的（审查 11）：剩下的顺序不变，一个都不剩时返回 nil。
    @Test func removingFilesKeepsTheRest() {
        let urls = ["file:///tmp/a.txt", "file:///tmp/b.txt", "file:///tmp/c.txt"]
        let snapshot = ClipSnapshot(items: urls.map { ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.fileURL, data: Data($0.utf8))]) })
        let kept = snapshot.removingFiles([URL(string: urls[1])!])
        #expect(kept?.fileURLs.map(\.absoluteString) == [urls[0], urls[2]])
        #expect(snapshot.removingFiles(Set(urls.compactMap(URL.init(string:)))) == nil)
        #expect(snapshot.removingFiles([])?.fileURLs.count == 3)
    }

    @Test func emptyAuxiliaryItemIsDropped() {
        let aux = NSPasteboardItem()
        aux.setData(Data("meta".utf8), forType: .init("com.example.private"))
        let real = NSPasteboardItem()
        real.setString("text", forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects([aux, real])

        guard case .snapshot(let snapshot) = read() else { Issue.record("expected snapshot"); return }
        #expect(snapshot.items.count == 1)
        #expect(snapshot.plainText == "text")
    }

    @Test func concealedOnAnyItemSkipsEverything() {
        let visible = NSPasteboardItem()
        visible.setString("password", forType: .string)
        let marker = NSPasteboardItem()
        marker.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        pasteboard.clearContents()
        pasteboard.writeObjects([visible, marker])

        #expect(read() == .skipped(.confidential))
    }

    @Test func ownWriteIsSkippedAndPlainTextStripsRichFormats() {
        let snapshot = ClipSnapshot(items: [ClipItemSnapshot(representations: [
            rep(ClipType.plainText, "hi"), rep(ClipType.rtf, "{\\rtf1 hi}"),
        ])])

        PasteboardWriter.write(snapshot, to: pasteboard)
        #expect(read() == .skipped(.ownWrite))
        #expect(pasteboard.pasteboardItems?.first?.data(forType: .rtf) != nil)

        PasteboardWriter.write(snapshot, to: pasteboard, plainTextOnly: true)
        #expect(pasteboard.pasteboardItems?.first?.data(forType: .rtf) == nil)
        #expect(pasteboard.string(forType: .string) == "hi")
    }

    @Test func plainTextModeConvertsRichOnlyContent() {
        let snapshot = ClipSnapshot(items: [ClipItemSnapshot(representations: [rep(ClipType.rtf, "{\\rtf1\\ansi {\\b BOLD}}")])])
        PasteboardWriter.write(snapshot, to: pasteboard, plainTextOnly: true)
        #expect(pasteboard.pasteboardItems?.first?.data(forType: .rtf) == nil)
        #expect(pasteboard.string(forType: .string) == "BOLD")
    }

    @Test func plainTextModeKeepsImages() {
        let snapshot = ClipSnapshot(items: [ClipItemSnapshot(representations: [rep(ClipType.png, "not really png")])])
        PasteboardWriter.write(snapshot, to: pasteboard, plainTextOnly: true)
        #expect(pasteboard.pasteboardItems?.first?.data(forType: .png) != nil)
    }

    /// 一个文本 item 加一个图片 item：纯文本模式只交出文本，不带图片（审查 GH-02）。
    @Test func plainTextModeDropsNonTextItemsWhenTextExists() {
        let snapshot = ClipSnapshot(items: [
            ClipItemSnapshot(representations: [rep(ClipType.plainText, "caption"), rep(ClipType.rtf, "{\\rtf1\\ansi caption}")]),
            ClipItemSnapshot(representations: [rep(ClipType.png, "not really png")]),
        ])
        PasteboardWriter.write(snapshot, to: pasteboard, plainTextOnly: true)
        #expect(pasteboard.pasteboardItems?.count == 1)
        #expect(pasteboard.string(forType: .string) == "caption")
        #expect(pasteboard.data(forType: .png) == nil)
    }

    @Test func plainTextModeKeepsFiles() {
        let snapshot = ClipSnapshot(items: [ClipItemSnapshot(representations: [
            rep(ClipType.fileURL, "file:///tmp/a.txt"), rep(ClipType.plainText, "a.txt"),
        ])])
        PasteboardWriter.write(snapshot, to: pasteboard, plainTextOnly: true)
        #expect(pasteboard.pasteboardItems?.first?.string(forType: .fileURL) == "file:///tmp/a.txt")
    }

    @Test func emptyPasteboardIsNotReady() {
        pasteboard.clearContents()
        #expect(read() == .notReady)
    }

    /// 读到一半时另一个应用改写了剪贴板（R18）：这次结果作废，不能把 A 的正文和 B 的图片拼成一条；再读拿到的只有 B。
    @Test func rewriteDuringReadDiscardsTheSnapshot() throws {
        final class Rewriter: NSObject, NSPasteboardItemDataProvider {
            let png: Data
            init(png: Data) { self.png = png }
            func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
                item.setString("A 的正文", forType: type)
                pasteboard?.clearContents()
                pasteboard?.setData(png, forType: .png)
            }
        }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let rewriter = Rewriter(png: png)
        let item = NSPasteboardItem()
        #expect(item.setDataProvider(rewriter, forTypes: [.string]))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        #expect(read() == .changedDuringRead)
        guard case .snapshot(let after) = read() else { Issue.record("expected snapshot"); return }
        #expect(after.items.count == 1 && after.items[0].data(for: ClipType.png) == png && after.items[0].data(for: ClipType.plainText) == nil)
    }
}

@MainActor
@Suite struct MonitorTests {
    @Test func changedPolicyDoesNotBackfillAndAppliesToNextCopy() async {
        let pasteboard = NSPasteboard.withUniqueName()
        let monitor = PasteboardMonitor(pasteboard: pasteboard)
        monitor.sourceProvider = { ClipSource(bundleID: "com.example.ignored", name: nil) }
        var captured: [ClipSnapshot] = []
        var skipped: [CapturePolicy.SkipReason] = []
        monitor.onCapture = { captured.append($0) }
        monitor.onSkip = { skipped.append($0) }
        pasteboard.setString("copied before the change", forType: .string)
        monitor.policy.ignoredBundleIDs = ["com.example.ignored"]
        monitor.tick()
        await monitor.settle()
        #expect(captured.isEmpty && skipped.isEmpty)
        pasteboard.clearContents()
        pasteboard.setString("new ignored copy", forType: .string)
        monitor.tick()
        await monitor.settle()
        #expect(captured.isEmpty && skipped == [.ignoredApp])
        monitor.policy.ignoredBundleIDs = []
        monitor.tick()
        await monitor.settle()
        #expect(captured.isEmpty)
        pasteboard.clearContents()
        pasteboard.setString("new allowed copy", forType: .string)
        monitor.tick()
        await monitor.settle()
        #expect(captured.map(\.plainText) == ["new allowed copy"])
    }

    @Test func capturesOnceAndIgnoresOwnWriteAndPause() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let monitor = PasteboardMonitor(pasteboard: pasteboard)
        monitor.sourceProvider = { ClipSource(bundleID: nil, name: nil) }
        var captured: [ClipSnapshot] = []
        monitor.onCapture = { captured.append($0) }

        pasteboard.clearContents()
        pasteboard.setString("one", forType: .string)
        monitor.tick()
        await monitor.settle()
        monitor.tick()
        await monitor.settle()
        #expect(captured.map(\.plainText) == ["one"])

        // 自己写回的内容不再入库。
        // 前面的断言失败时 captured 可能是空的：先确认再取，免得越界中止整个测试进程。
        PasteboardWriter.write(try #require(captured.first), to: pasteboard)
        monitor.tick()
        await monitor.settle()
        #expect(captured.count == 1)

        // 暂停期间的复制，恢复后不补录。
        monitor.setPaused(true)
        pasteboard.clearContents()
        pasteboard.setString("while paused", forType: .string)
        monitor.tick()
        await monitor.settle()
        monitor.setPaused(false)
        monitor.tick()
        await monitor.settle()
        #expect(captured.count == 1)

        pasteboard.clearContents()
        pasteboard.setString("two", forType: .string)
        monitor.tick()
        await monitor.settle()
        #expect(captured.map(\.plainText) == ["one", "two"])

        // 暂停时计时器停掉，恢复后重新开始；停止采集后暂停再恢复也不会自己开起来。
        monitor.start()
        #expect(monitor.isPolling)
        monitor.setPaused(true)
        #expect(!monitor.isPolling)
        monitor.setPaused(false)
        #expect(monitor.isPolling)
        monitor.stop()
        monitor.setPaused(true)
        monitor.setPaused(false)
        #expect(!monitor.isPolling)

        // 用户离开 60 秒以上：放慢到每秒一次；一有操作恢复。
        var idle: TimeInterval = 0
        monitor.secondsSinceUserInput = { idle }
        monitor.start()
        #expect(monitor.currentInterval == 0.25)
        idle = 61
        monitor.adjustCadence()
        #expect(monitor.currentInterval == 1 && monitor.isPolling)
        idle = 2
        monitor.adjustCadence()
        #expect(monitor.currentInterval == 0.25)
        monitor.idleAfter = nil
        idle = 600
        monitor.adjustCadence()
        #expect(monitor.currentInterval == 0.25)
        monitor.stop()
    }

    /// 读取在后台进行（R26）：读的过程中暂停、改了设置或停止采集，回来的结果作废。
    @Test func readFinishingAfterPauseIsDropped() async {
        let pasteboard = NSPasteboard.withUniqueName()
        let monitor = PasteboardMonitor(pasteboard: pasteboard)
        monitor.sourceProvider = { ClipSource(bundleID: nil, name: nil) }
        var captured: [ClipSnapshot] = []
        monitor.onCapture = { captured.append($0) }
        pasteboard.clearContents()
        pasteboard.setString("read in flight", forType: .string)
        monitor.tick()
        monitor.setPaused(true)
        await monitor.settle()
        monitor.setPaused(false)
        monitor.tick()
        await monitor.settle()
        #expect(captured.isEmpty)

        pasteboard.clearContents()
        pasteboard.setString("before the policy change", forType: .string)
        monitor.tick()
        monitor.policy.ignoredBundleIDs = ["com.example.other"]
        await monitor.settle()
        #expect(captured.isEmpty)

        pasteboard.clearContents()
        pasteboard.setString("before stopping", forType: .string)
        monitor.start()
        monitor.tick()
        monitor.stop()
        await monitor.settle()
        #expect(captured.isEmpty)
    }

    /// N01：计数先变、数据稍后才写进来时，同一次复制在有限次重试里采到，而且只采一次。
    @Test func lateDataIsPickedUpByARetry() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let monitor = PasteboardMonitor(pasteboard: pasteboard)
        monitor.sourceProvider = { ClipSource(bundleID: nil, name: nil) }
        var captured: [ClipSnapshot] = []
        monitor.onCapture = { captured.append($0) }
        pasteboard.declareTypes([.string], owner: nil)
        let count = pasteboard.changeCount
        monitor.tick()
        await monitor.settle()
        #expect(captured.isEmpty)
        try await Task.sleep(for: .milliseconds(60))
        pasteboard.setString("arrived late", forType: .string)
        #expect(pasteboard.changeCount == count)
        for _ in 0..<20 where captured.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
            await monitor.settle()
        }
        try await Task.sleep(for: .milliseconds(400))
        monitor.tick()
        await monitor.settle()
        #expect(captured.map(\.plainText) == ["arrived late"])
    }

    /// L168：计数变了、数据一直不来时，重试用完要报告放弃（以前这条路径不留痕迹），并且什么也不采集。
    @Test func givingUpOnDataThatNeverArrivesIsReported() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let monitor = PasteboardMonitor(pasteboard: pasteboard)
        monitor.sourceProvider = { ClipSource(bundleID: nil, name: nil) }
        var captured: [ClipSnapshot] = []
        var gaveUp: [Int] = []
        monitor.onCapture = { captured.append($0) }
        monitor.onGiveUp = { gaveUp.append($0) }
        pasteboard.declareTypes([.string], owner: nil)
        let count = pasteboard.changeCount
        monitor.tick()
        // 重试间隔一共 0.35 秒，留足余量。
        for _ in 0..<20 where gaveUp.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
            await monitor.settle()
        }
        #expect(gaveUp == [count])
        #expect(captured.isEmpty)
    }
}

@MainActor
@Suite struct KeyboardLayoutTests {
    /// 当前布局下总能解析出一个有效键码；标准 QWERTY 布局应为 9。
    @Test func resolvesKeyCodeForCommandV() {
        let code = PastePerformer.keyCodeForCommandV()
        #expect(code < 128)
        print("KEYCODE ⌘V = \(code)")
    }

    /// V04：不切换输入法，直接取系统装着的布局来算。Dvorak 的 V 在 QWERTY 句点键的位置；
    /// “Dvorak – QWERTY ⌘”按住 ⌘ 时回到 QWERTY，仍是 9。
    @Test func resolvesKeyCodeInOtherLayouts() throws {
        func layout(_ id: String) -> TISInputSource? {
            let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
            return (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])?.first
        }
        let cases: [(String, Int)] = [("com.apple.keylayout.ABC", kVK_ANSI_V), ("com.apple.keylayout.US", kVK_ANSI_V),
                                      ("com.apple.keylayout.Dvorak", kVK_ANSI_Period), ("com.apple.keylayout.DVORAK-QWERTYCMD", kVK_ANSI_V)]
        for (id, expected) in cases {
            let source = try #require(layout(id), "\(id) 不在本机")
            #expect(PastePerformer.keyCodeForCommandV(in: source) == CGKeyCode(expected), "\(id)")
        }
    }
}
