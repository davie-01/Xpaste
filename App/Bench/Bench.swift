#if BENCH
import AppKit
import ClipboardKit
import PasteCore

/// 测量构建（Profile 配置）的入口。`XPASTE_BENCH=<场景>` 启动后跑一个场景，结果按行打印成 `BENCH {json}`，然后退出。
///
/// 隔离：数据放在临时目录，偏好只用 `AppPreferences.benchSuite`，采集和回放只读写命名剪贴板 `com.mars.XPaste.bench`；
/// 不注册全局快捷键，不放音效（`sound` 场景除外），不启动 MCP，不取链接信息，不向任何应用发 ⌘V。结束时临时目录、偏好域和命名剪贴板都清掉。
/// 场景和参数见 `Tools/bench/run.sh` 和 Docs/07 第 3 节。
@MainActor
enum Bench {
    static let pasteboardName = "com.mars.XPaste.bench"
    static var shouldRun: Bool { true }

    private static let env = ProcessInfo.processInfo.environment
    private static func string(_ key: String, _ fallback: String) -> String { env["XPASTE_BENCH_\(key)"].flatMap { $0.isEmpty ? nil : $0 } ?? fallback }
    private static func int(_ key: String, _ fallback: Int) -> Int { env["XPASTE_BENCH_\(key)"].flatMap(Int.init) ?? fallback }
    private static func double(_ key: String, _ fallback: Double) -> Double { env["XPASTE_BENCH_\(key)"].flatMap(Double.init) ?? fallback }

    private static let scenarios: [String: @MainActor (Context) async throws -> Void] = [
        "idle": idle, "cadence": cadence, "lifecycle": lifecycle, "retention": retention,
        "scroll": scroll, "search": search, "image": image, "stack": stack, "sound": sound, "ocr": ocr,
    ]

    static func run() async {
        let name = env["XPASTE_BENCH"] ?? ""
        guard let scenario = scenarios[name] else {
            print("XPaste 的 Profile 构建只用于测量。用法：XPASTE_BENCH=<\(scenarios.keys.sorted().joined(separator: "|"))> 启动；参数见 Tools/bench/run.sh")
            exit(2)
        }
        UserDefaults().removePersistentDomain(forName: AppPreferences.benchSuite)
        let preferences = AppPreferences.shared
        preferences.soundEffectsEnabled = false
        preferences.generateLinkPreviews = false
        preferences.onboardingCompleted = true
        preferences.pasteToApplication = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xpaste-bench-\(UUID().uuidString)", isDirectory: true)
        let pasteboard = NSPasteboard(name: .init(pasteboardName))
        var failed = false
        do {
            let context = Context(name: name, directory: directory, store: try HistoryStore(directory: directory), pasteboard: pasteboard)
            emit(["scenario": name, "event": "start", "pid": Int(getpid())])
            try await scenario(context)
        } catch {
            emit(["scenario": name, "event": "error", "error": "\(error)"])
            failed = true
        }
        try? FileManager.default.removeItem(at: directory)
        UserDefaults().removePersistentDomain(forName: AppPreferences.benchSuite)
        pasteboard.releaseGlobally()
        emit(["scenario": name, "event": "end", "ok": !failed])
        exit(failed ? 1 : 0)
    }

    @MainActor struct Context {
        let name: String
        let directory: URL
        let store: HistoryStore
        let pasteboard: NSPasteboard

        func makePanel() -> PanelController {
            let panel = PanelController(store: store)
            panel.animationsEnabled = Bench.int("ANIMATE", 0) == 1
            return panel
        }

        func makeMonitor(interval: TimeInterval) -> PasteboardMonitor {
            let monitor = PasteboardMonitor(pasteboard: pasteboard, interval: interval)
            // 测量要固定的间隔，不按用户是否离开放慢（无人值守时一直算“离开”）。
            if env["XPASTE_BENCH_ADAPTIVE"] != "1" { monitor.idleAfter = nil }
            monitor.policy = AppPreferences.shared.capturePolicy
            return monitor
        }

        func emit(_ fields: [String: Any]) {
            Bench.emit(fields.merging(["scenario": name]) { current, _ in current })
        }
    }

    // MARK: B1、B2、B12：空闲

    /// 采集开着、没有新复制，记一段时间里的 CPU、唤醒、写盘和内存。`PANEL=visible` 时面板一直开着（B2）。
    private static func idle(_ context: Context) async throws {
        let items = int("ITEMS", 0)
        let interval = double("INTERVAL", 0.25)
        let visible = string("PANEL", "hidden") == "visible"
        let warmup = double("WARMUP", 300)
        let duration = double("DURATION", 900)
        try seed(context.store, count: items)

        let panel = context.makePanel()
        let monitor = context.makeMonitor(interval: interval)
        var captures = 0
        monitor.onCapture = { snapshot in
            captures += 1
            _ = try? context.store.record(snapshot)
            panel.historyDidChange()
        }
        monitor.start()
        // 和正式启动一样：每小时一次的保留期限清理、后台的图片文字识别。
        let store = context.store
        let retention = Timer(timeInterval: 3_600, repeats: true) { _ in
            try? store.applyRetention(AppPreferences.shared.retention)
        }
        retention.tolerance = 300
        RunLoop.main.add(retention, forMode: .common)
        let ocr = OCRIndexer(store: context.store) { try await TextRecognition.recognize($0) }
        Task { await ocr.kick() }
        if visible {
            panel.show()
            await panel.debugSettle()
        }

        // 种子数据里的图片先识别完（最多等 10 分钟），否则测到的是识别的开销而不是空闲。
        let ocrStart = ContinuousClock.now
        while try context.store.nextImageAwaitingOCR() != nil, ContinuousClock.now - ocrStart < .seconds(600) {
            try await Task.sleep(for: .seconds(1))
        }
        let ocrWait = (ContinuousClock.now - ocrStart).seconds
        try await Task.sleep(for: .seconds(warmup))
        let ocrPending = try context.store.nextImageAwaitingOCR() != nil
        let before = Sample.now()
        try await Task.sleep(for: .seconds(duration))
        let after = Sample.now()
        monitor.stop()
        retention.invalidate()
        if visible { panel.hide() }
        context.emit(["event": "result", "items": items, "interval": interval, "panel": visible ? "visible" : "hidden",
                      "warmup_s": warmup, "ocr_wait_s": ocrWait, "ocr_pending_at_start": ocrPending, "captures": captures]
            .merging(after.delta(from: before)) { $1 })
    }

    // MARK: B3、B12：复制节奏

    /// 另起一个进程按固定间隔往命名剪贴板写带序号和时间戳的文本，统计采到几条、漏了哪些、延迟分布。
    private static func cadence(_ context: Context) async throws {
        let interval = double("INTERVAL", 0.25)
        let count = int("COUNT", 200)
        let gaps = string("GAPS", "50,100,250,500,1000").split(separator: ",").compactMap { Int($0) }
        guard let writer = env["XPASTE_BENCH_WRITER"] else { throw BenchError("缺少 XPASTE_BENCH_WRITER（Tools/bench/pbwrite 的路径）") }
        try seed(context.store, count: int("ITEMS", 0))

        let monitor = context.makeMonitor(interval: interval)
        var latencies: [Int: Double] = [:]
        var recordErrors = 0
        var foreign = 0
        var run = 0
        monitor.onCapture = { snapshot in
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            do { _ = try context.store.record(snapshot) } catch { recordErrors += 1 }
            let parts = (snapshot.plainText ?? "").split(separator: " ")
            guard parts.count == 4, parts[0] == "xpaste-bench", Int(parts[1]) == run, let seq = Int(parts[2]), let sent = UInt64(parts[3]) else {
                foreign += 1
                return
            }
            latencies[seq] = Double(now &- sent) / 1_000_000
        }
        monitor.start()
        for gap in gaps {
            run += 1
            latencies = [:]
            recordErrors = 0
            foreign = 0
            try await Task.sleep(for: .seconds(1))
            let before = Sample.now()
            let wrote = try await runWriter(writer, run: run, count: count, gapMs: gap)
            // 最后一条写完后再等几个轮询周期，让它也有机会被采到。
            try await Task.sleep(for: .seconds(max(1, interval * 4)))
            let after = Sample.now()
            let values = latencies.values.sorted()
            let missing = (0..<count).filter { latencies[$0] == nil }
            context.emit(["event": "result", "interval": interval, "gap_ms": gap, "count": count, "writer_wrote": wrote,
                          "captured": latencies.count, "missing": missing.count, "missing_first": Array(missing.prefix(20)),
                          "record_errors": recordErrors, "foreign": foreign,
                          "latency_ms": percentiles(values)].merging(after.delta(from: before)) { $1 })
        }
        monitor.stop()
    }

    private static func runWriter(_ path: String, run: Int, count: Int, gapMs: Int) async throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [pasteboardName, "\(run)", "\(count)", "\(gapMs)"]
        let output = Pipe()
        process.standardOutput = output
        // 边跑边读输出：等进程结束再读，输出超过管道缓冲时双方会互相等住（审查：进程与并发）。另给 10 分钟上限。
        let collected = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
        try process.run()
        let timeout = Task.detached { [process] in
            try? await Task.sleep(for: .seconds(600))
            if process.isRunning { process.terminate() }
        }
        let data = await collected.value
        await Task.detached { process.waitUntilExit() }.value
        timeout.cancel()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0, let wrote = Int(text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").last ?? "") else {
            throw BenchError("写入程序失败（\(process.terminationStatus)）：\(text)")
        }
        return wrote
    }

    // MARK: B8：生命周期与 L46

    /// 面板开关、采集启停、隐私设置切换、Stack 开关各重复多次，每批后记窗口、线程、文件句柄和内存。
    /// `HOLD=<目录>` 时在第一批和最后一批面板开关之后停下，等目录里出现 `continue-<标记>` 再继续，供脚本抓 heap 和 leaks。
    private static func lifecycle(_ context: Context) async throws {
        let batches = int("BATCHES", 5)
        let cycles = int("CYCLES", 1_000)
        let holdDirectory = env["XPASTE_BENCH_HOLD"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        try seed(context.store, count: int("ITEMS", 1_000))

        func hold(_ label: String) async {
            guard let holdDirectory else { return }
            let marker = holdDirectory.appendingPathComponent("continue-\(label)")
            context.emit(["event": "hold", "label": label, "pid": Int(getpid())])
            while !FileManager.default.fileExists(atPath: marker.path) { try? await Task.sleep(for: .milliseconds(200)) }
        }
        func report(_ phase: String, batch: Int, _ extra: [String: Any] = [:]) async {
            try? await Task.sleep(for: .milliseconds(500))
            context.emit(["event": "result", "phase": phase, "batch": batch, "cycles": cycles].merging(Sample.now().absolute) { $1 }.merging(extra) { $1 })
        }

        let panel = context.makePanel()
        await report("baseline", batch: 0)
        for batch in 1...batches {
            for i in 0..<cycles {
                autoreleasepool { panel.show(); panel.hide() }
                if i % 25 == 24 { try? await Task.sleep(for: .milliseconds(5)) }
            }
            await report("panel", batch: batch, ["refresh_timer": panel.debugHasRefreshTimer, "loaded": panel.debugLoadedCount])
            if batch == 1 { await hold("panel-first") }
            if batch == batches { await hold("panel-last") }
        }

        let monitor = context.makeMonitor(interval: 0.25)
        for i in 0..<cycles {
            monitor.start()
            monitor.stop()
            if i % 100 == 99 { try? await Task.sleep(for: .milliseconds(1)) }
        }
        await report("monitor", batch: 1, ["running": monitor.isRunning])

        let preferences = AppPreferences.shared
        for i in 0..<cycles {
            preferences.ignoreTransient.toggle()
            monitor.policy = preferences.capturePolicy
            panel.privacyDidChange()
            if i % 100 == 99 { try? await Task.sleep(for: .milliseconds(1)) }
        }
        await report("privacy", batch: 1)

        let stack = StackController(store: context.store, pasteboard: context.pasteboard, interceptsPaste: false) { _ in }
        for i in 0..<(cycles / 5) {
            autoreleasepool { stack.open(); stack.close() }
            if i % 25 == 24 { try? await Task.sleep(for: .milliseconds(5)) }
        }
        await report("stack", batch: 1, ["open": stack.isOpen])
        // 线程数在开关后的一段时间里会偏高（系统的工作线程还没退出），静置几秒再取一次。
        try? await Task.sleep(for: .seconds(5))
        await report("stack-settled", batch: 1)
    }

    // MARK: B9：淘汰、R01、R13

    /// 写入大量过期条目和少量新条目，按保留期限清理后查孤儿和文件大小，重新打开再查一遍；
    /// 回放 100 次确认不产生自己的条目；删除正在预览的条目。
    private static func retention(_ context: Context) async throws {
        let count = int("ITEMS", 10_000)
        let keep = int("KEEP", 100)
        let store = context.store
        let old = Date().addingTimeInterval(-40 * 86_400)
        var random = SeededRandom(seed: 9)
        let png = tinyPNG()
        let start = ContinuousClock.now
        var pinned: [Int64] = []
        for i in 0..<count {
            let isRecent = i >= count - keep
            let rep: ClipRepresentation = i % 20 == 0
                // 超过 256 KB 的图片存成外置文件，用来检查删除后有没有留下孤儿文件。
                ? ClipRepresentation(type: ClipType.png, data: png + random.bytes(300 * 1024))
                : ClipRepresentation(type: ClipType.plainText, data: Data(benchText(i, &random).utf8))
            let summary = try store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [rep])]),
                                           now: isRecent ? Date().addingTimeInterval(Double(i - count)) : old.addingTimeInterval(Double(i)))
            if !isRecent, i % 500 == 0 { pinned.append(summary.id) }
        }
        let board = try store.createPinboard(name: "测量", colorHex: "#4B8DF7")
        try store.pin(ids: pinned, to: board.id)
        let seedSeconds = (ContinuousClock.now - start).seconds
        let sizesBefore = storageSizes(context.directory)

        let cleanStart = ContinuousClock.now
        try store.applyRetention(.month)
        let cleanMs = (ContinuousClock.now - cleanStart).milliseconds
        let historyLeft = try store.clips(matching: ClipQuery(), limit: count).count
        let pinnedLeft = try store.clips(matching: ClipQuery(scope: .pinboard(board.id)), limit: count).count
        let report = try store.integrityReport()
        let sizesAfter = storageSizes(context.directory)
        let reopened = try HistoryStore(directory: context.directory)
        let reopenedReport = try reopened.integrityReport()
        context.emit(["event": "result", "phase": "retention", "items": count, "keep": keep, "seed_s": seedSeconds, "clean_ms": cleanMs,
                      "history_left": historyLeft, "pinned_left": pinnedLeft, "pinned_expected": pinned.count,
                      "integrity_clean": report.isClean, "integrity": "\(report)", "reopened_clean": reopenedReport.isClean,
                      "before": sizesBefore, "after": sizesAfter, "after_reopen": storageSizes(context.directory)])

        // R13：回放写回剪贴板后，采集器不把这次变化当成新复制。
        let monitor = context.makeMonitor(interval: 0.25)
        var captured = 0
        monitor.onCapture = { _ in captured += 1 }
        monitor.start()
        let clips = try store.clips(matching: ClipQuery(), limit: 100)
        for clip in clips {
            guard let snapshot = try store.snapshot(id: clip.id) else { continue }
            if let changeCount = PasteboardWriter.write(snapshot, to: context.pasteboard) { monitor.acknowledge(changeCount: changeCount) }
            monitor.tick()
        }
        try await Task.sleep(for: .seconds(1))
        monitor.stop()
        let historyAfterReplay = try store.clips(matching: ClipQuery(), limit: count).count
        context.emit(["event": "result", "phase": "replay", "replayed": clips.count, "captured": captured,
                      "history_before": historyLeft, "history_after": historyAfterReplay])

        // 删除正在预览的条目：浮层跟着关掉或换到下一条，不崩溃。
        let panel = context.makePanel()
        panel.show()
        await panel.debugSettle()
        panel.debugPress(keyCode: 49, characters: " ")
        await panel.debugSettle()
        let previewed = panel.debugPreviewClipID
        if let previewed { try store.removeFromHistory(ids: [previewed]) }
        panel.historyDidChange()
        await panel.debugSettle()
        let previewAfter = panel.debugPreviewClipID
        panel.hide()
        context.emit(["event": "result", "phase": "delete-previewed", "previewed": previewed.map { Int($0) } ?? -1,
                      "preview_after": previewAfter.map { Int($0) } ?? -1, "removed_still_shown": previewAfter != nil && previewAfter == previewed,
                      "integrity_clean": try store.integrityReport().isClean])
    }

    // MARK: V17：滚动

    /// 面板开着，用显示刷新回调匀速横向滚动整段历史（到头就往回），按帧间隔统计掉帧。
    private static func scroll(_ context: Context) async throws {
        let items = int("ITEMS", 10_000)
        let duration = double("DURATION", 20)
        let speed = double("SPEED", 3_000)
        try seed(context.store, count: items)
        let panel = context.makePanel()
        panel.show()
        await panel.debugSettle()
        try await Task.sleep(for: .seconds(1))

        let scrollView = panel.debugScrollView
        let driver = ScrollDriver(scrollView: scrollView, speed: speed)
        let link = scrollView.displayLink(target: driver, selector: #selector(ScrollDriver.step(_:)))
        let before = Sample.now()
        link.add(to: .main, forMode: .common)
        try await Task.sleep(for: .seconds(duration))
        link.invalidate()
        let after = Sample.now()
        let loaded = panel.debugLoadedCount
        panel.hide()

        let intervals = driver.intervals.sorted()
        let nominal = driver.nominal
        let hitches = driver.intervals.filter { $0 > nominal * 1.5 }
        context.emit(["event": "result", "items": items, "duration_s": duration, "speed_px_s": speed, "frames": driver.intervals.count,
                      "nominal_ms": nominal * 1_000, "frame_ms": percentiles(intervals.map { $0 * 1_000 }),
                      "hitches": hitches.count, "hitch_ms_per_s": hitches.reduce(0) { $0 + $1 - nominal } * 1_000 / duration,
                      "reversals": driver.reversals, "loaded": loaded].merging(after.delta(from: before)) { $1 })
    }

    // MARK: L44、L45：搜索

    /// 每个搜索词直接查库若干次，再走一遍面板的搜索路径（主线程只发起查询，结果在后台算）。
    private static func search(_ context: Context) async throws {
        let items = int("ITEMS", 10_000)
        let repeats = int("REPEATS", 50)
        let terms = string("TERMS", "a,的,ab,报告,xp,lor,lorem,xpaste,quarterly report,不存在的词语").split(separator: ",").map(String.init)
        try seed(context.store, count: items)
        let store = context.store

        for term in terms {
            var times: [Double] = []
            var hits = 0
            for _ in 0..<repeats {
                let start = ContinuousClock.now
                hits = try store.clips(matching: ClipQuery(text: term), limit: 51).count
                times.append((ContinuousClock.now - start).milliseconds)
            }
            context.emit(["event": "result", "path": "store", "items": items, "term": term, "length": term.count, "hits": hits,
                          "query_ms": percentiles(times.sorted())])
        }

        let panel = context.makePanel()
        panel.show()
        await panel.debugSettle()
        let heartbeat = Heartbeat()
        for term in terms {
            var main: [Double] = []
            var total: [Double] = []
            heartbeat.start()
            for _ in 0..<max(1, repeats / 5) {
                panel.debugSearch("")
                await panel.debugSettle()
                let start = ContinuousClock.now
                panel.debugSearch(term)
                main.append((ContinuousClock.now - start).milliseconds)
                await panel.debugSettle()
                total.append((ContinuousClock.now - start).milliseconds)
            }
            context.emit(["event": "result", "path": "panel", "items": items, "term": term, "main_ms": percentiles(main.sorted()),
                          "total_ms": percentiles(total.sorted()), "main_stall_max_ms": heartbeat.stop()])
        }
        panel.hide()
    }

    // MARK: L09、L28：大图

    /// 每种尺寸生成一张图：记录入库、读取、解码、空格预览（主线程用时和出图用时）、旋转、编码、抠图的耗时。
    private static func image(_ context: Context) async throws {
        let sizes = string("SIZES", "2000x1500,4000x3000,8000x6000").split(separator: ",").compactMap { spec -> (Int, Int)? in
            let parts = spec.split(separator: "x").compactMap { Int($0) }
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        let liftLimit = int("LIFT_MAX_PIXELS", 50_000_000)
        try seed(context.store, count: int("ITEMS", 200))
        let panel = context.makePanel()
        let heartbeat = Heartbeat()

        for (width, height) in sizes {
            let data = noisyPNG(width: width, height: height)
            let snapshot = ClipSnapshot(items: [ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.png, data: data)])])
            var start = ContinuousClock.now
            let summary = try context.store.record(snapshot)
            let recordMs = (ContinuousClock.now - start).milliseconds

            start = ContinuousClock.now
            let stored = try context.store.imageData(id: summary.id) ?? Data()
            let readMs = (ContinuousClock.now - start).milliseconds

            panel.show()
            await panel.debugSettle()
            panel.debugSelect(index: 0)
            heartbeat.start()
            start = ContinuousClock.now
            panel.debugPress(keyCode: 49, characters: " ")
            let previewMainMs = (ContinuousClock.now - start).milliseconds
            await panel.debugSettle()
            panel.debugForceLayout()
            let previewReadyMs = (ContinuousClock.now - start).milliseconds
            let previewStall = heartbeat.stop()
            let previewed = panel.debugPreviewClipID == summary.id
            panel.hide()
            let footprintAfterPreview = Sample.now().footprintMB

            start = ContinuousClock.now
            guard let decoded = ImageEditing.decode(stored) else { throw BenchError("解码失败 \(width)x\(height)") }
            // 解码是惰性的，画一次才真正解出像素。
            _ = decoded.dataProvider?.data
            let decodeMs = (ContinuousClock.now - start).milliseconds
            start = ContinuousClock.now
            let rotated = ImageEditing.rotated(decoded, quarterTurns: 1)
            let rotateMs = (ContinuousClock.now - start).milliseconds
            start = ContinuousClock.now
            let encoded = rotated.flatMap(ImageEditing.png)
            let encodeMs = (ContinuousClock.now - start).milliseconds
            var liftMs: Double?
            if width * height <= liftLimit {
                start = ContinuousClock.now
                _ = await ImageEditing.liftSubject(from: decoded)
                liftMs = (ContinuousClock.now - start).milliseconds
            }
            context.emit(["event": "result", "width": width, "height": height, "png_mb": Double(data.count) / 1_048_576,
                          "record_ms": recordMs, "read_ms": readMs, "preview_main_ms": previewMainMs, "preview_ready_ms": previewReadyMs,
                          "preview_stall_max_ms": previewStall, "previewed": previewed, "decode_ms": decodeMs, "rotate_ms": rotateMs,
                          "encode_ms": encodeMs, "encoded_mb": Double(encoded?.count ?? 0) / 1_048_576, "lift_ms": liftMs.map { $0 as Any } ?? NSNull(),
                          "footprint_after_preview_mb": footprintAfterPreview, "footprint_mb": Sample.now().footprintMB])
        }
    }

    // MARK: L72：Stack 大内容

    /// Stack 队列里放大文本和大图，测按 ⌘V 时同步写剪贴板的用时（事件拦截的回调里做的就是这一步）。
    private static func stack(_ context: Context) async throws {
        let textSizes = string("TEXT_MB", "1,10,50,100").split(separator: ",").compactMap { Int($0) }
        let imageSizes = string("IMAGE_SIZES", "4000x3000,8000x6000").split(separator: ",").compactMap { spec -> (Int, Int)? in
            let parts = spec.split(separator: "x").compactMap { Int($0) }
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        var random = SeededRandom(seed: 3)
        var contents: [(String, ClipSnapshot)] = textSizes.map { mb in
            var text = ""
            text.reserveCapacity(mb * 1_048_576)
            while text.utf8.count < mb * 1_048_576 { text += benchText(text.utf8.count, &random) + "\n" }
            return ("text-\(mb)MB", ClipSnapshot(items: [ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.plainText, data: Data(text.utf8))])]))
        }
        contents += imageSizes.map { width, height in
            ("png-\(width)x\(height)", ClipSnapshot(items: [ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.png, data: noisyPNG(width: width, height: height))])]))
        }

        let stack = StackController(store: context.store, pasteboard: context.pasteboard, interceptsPaste: false) { _ in }
        let heartbeat = Heartbeat()
        for (label, snapshot) in contents {
            stack.open()
            let footprintBefore = Sample.now().footprintMB
            var start = ContinuousClock.now
            let summary = try context.store.record(snapshot)
            let recordMs = (ContinuousClock.now - start).milliseconds
            stack.collect(snapshot, summary: summary)
            let footprintQueued = Sample.now().footprintMB
            heartbeat.start()
            start = ContinuousClock.now
            let swallowed = stack.debugPressPaste()
            let writeMs = (ContinuousClock.now - start).milliseconds
            try await Task.sleep(for: .milliseconds(300))
            let stall = heartbeat.stop()
            stack.close()
            let bytes = snapshot.items.reduce(0) { $0 + $1.representations.reduce(0) { $0 + $1.data.count } }
            context.emit(["event": "result", "content": label, "mb": Double(bytes) / 1_048_576, "record_ms": recordMs, "write_ms": writeMs,
                          "swallowed": swallowed, "stall_max_ms": stall, "footprint_before_mb": footprintBefore, "footprint_queued_mb": footprintQueued,
                          "pasteboard_types": context.pasteboard.types?.count ?? 0])
        }
    }

    // MARK: B10：音效突发

    /// 音效开或关（`SOUND=1|0`），另起写入程序连着复制 `COUNT` 次；每次采到都照正式采集的顺序入库、刷新面板、放复制音。
    /// 之后静置，在 `SETTLE` 列出的秒数上取样，看线程、CPU 和内存能不能回落。开、关各起一个进程，免得前一轮的音频线程留下来。
    private static func sound(_ context: Context) async throws {
        let soundOn = int("SOUND", 1) == 1
        let count = int("COUNT", 100)
        // 比 250 ms 的轮询稍长，每次复制都能采到，也就每次都会尝试放音。
        let gap = int("GAP_MS", 300)
        let settle = string("SETTLE", "1,5,10,30,60").split(separator: ",").compactMap { Double($0) }
        guard let writer = env["XPASTE_BENCH_WRITER"] else { throw BenchError("缺少 XPASTE_BENCH_WRITER（Tools/bench/pbwrite 的路径）") }
        try seed(context.store, count: int("ITEMS", 1_000))

        let effects = SoundEffects { soundOn }
        let panel = context.makePanel()
        let monitor = context.makeMonitor(interval: 0.25)
        var captures = 0
        // 每次调用 play 的主线程用时，按调用顺序。
        var playMs: [Double] = []
        monitor.onCapture = { snapshot in
            captures += 1
            _ = try? context.store.record(snapshot)
            panel.historyDidChange()
            let start = ContinuousClock.now
            effects.play(.copy)
            playMs.append((ContinuousClock.now - start).milliseconds)
        }
        monitor.start()
        try await Task.sleep(for: .seconds(double("WARMUP", 10)))
        let idleStart = Sample.now()
        try await Task.sleep(for: .seconds(10))
        let before = Sample.now()
        context.emit(["event": "result", "phase": "baseline", "sound": soundOn].merging(before.delta(from: idleStart)) { $1 })

        let heartbeat = Heartbeat()
        heartbeat.start()
        let wrote = try await runWriter(writer, run: 1, count: count, gapMs: gap)
        try await Task.sleep(for: .seconds(1))
        let after = Sample.now()
        context.emit(["event": "result", "phase": "burst", "sound": soundOn, "count": count, "gap_ms": gap, "writer_wrote": wrote,
                      "captured": captures, "sounds_created": effects.debugCreatedCount, "main_stall_max_ms": heartbeat.stop(),
                      "play_ms": percentiles(playMs.sorted()), "play_first_ms": playMs.first ?? 0, "play_slowest": Array(playMs.enumerated().sorted { $0.element > $1.element }.prefix(5).map { [$0.offset, $0.element] })]
            .merging(after.delta(from: before)) { $1 })

        var last = after
        var elapsed = 0.0
        for mark in settle {
            try await Task.sleep(for: .seconds(mark - elapsed))
            elapsed = mark
            let now = Sample.now()
            context.emit(["event": "result", "phase": "settle", "sound": soundOn, "at_s": mark, "playing": effects.debugPlayingCount]
                .merging(now.delta(from: last)) { $1 })
            last = now
        }
        monitor.stop()
    }

    // MARK: V07：文字识别积压

    /// 一次放进 `IMAGES` 张带文字的图片（`SIZE` 宽×高），再启动识别：记总耗时、每张用时、CPU，以及内存和线程的峰值。
    /// 识别开始前和识别期间（每 `PANEL_EVERY` 秒）各唤起面板若干次，对比唤起用时。
    private static func ocr(_ context: Context) async throws {
        let count = int("IMAGES", 300)
        let size = string("SIZE", "1440x900").split(separator: "x").compactMap { Int($0) }
        guard size.count == 2 else { throw BenchError("SIZE 应为 宽x高") }
        let (width, height) = (size[0], size[1])
        let probes = int("PROBES", 10)
        let panelEvery = double("PANEL_EVERY", 2)
        let store = context.store
        try seed(store, count: int("ITEMS", 1_000))
        // 种子数据里的小图先用假的识别清掉，只留下这次要测的图片。
        let warmup = OCRIndexer(store: store) { _ in "" }
        await warmup.kick()
        await warmup.waitUntilIdle()

        var start = ContinuousClock.now
        var pngBytes = 0
        for i in 0..<count {
            let data = textPNG(width: width, height: height, index: i)
            pngBytes += data.count
            try store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.png, data: data)])],
                                          sourceBundleID: "com.apple.Safari", sourceName: "Safari"))
        }
        let recordSeconds = (ContinuousClock.now - start).seconds

        let panel = context.makePanel()
        var mainMs: [Double] = []
        var readyMs: [Double] = []
        func probe() async {
            let start = ContinuousClock.now
            panel.show()
            mainMs.append((ContinuousClock.now - start).milliseconds)
            await panel.debugSettle()
            panel.debugForceLayout()
            readyMs.append((ContinuousClock.now - start).milliseconds)
            panel.hide()
        }
        for _ in 0..<probes {
            await probe()
            try await Task.sleep(for: .milliseconds(500))
        }
        let baselineMain = percentiles(mainMs.sorted())
        let baselineReady = percentiles(readyMs.sorted())
        mainMs = []
        readyMs = []

        let log = RecognitionLog()
        let indexer = OCRIndexer(store: store) { data in
            let start = ContinuousClock.now
            let text = try await TextRecognition.recognize(data)
            await log.add((ContinuousClock.now - start).milliseconds, characters: text.count)
            return text
        }
        let heartbeat = Heartbeat()
        heartbeat.start()
        let before = Sample.now()
        var peakFootprint = before.footprintMB
        var peakThreads = before.threads
        start = ContinuousClock.now
        await indexer.kick()
        var lastProbe = ContinuousClock.now
        while try store.nextImageAwaitingOCR() != nil, ContinuousClock.now - start < .seconds(double("TIMEOUT", 1_800)) {
            try await Task.sleep(for: .milliseconds(500))
            let sample = Sample.now()
            peakFootprint = max(peakFootprint, sample.footprintMB)
            peakThreads = max(peakThreads, sample.threads)
            if ContinuousClock.now - lastProbe >= .seconds(panelEvery) {
                await probe()
                lastProbe = .now
            }
        }
        let pending = try store.nextImageAwaitingOCR() != nil
        await indexer.cancel()
        await indexer.waitUntilIdle()
        let ocrSeconds = (ContinuousClock.now - start).seconds
        let after = Sample.now()
        let stall = heartbeat.stop()
        let durations = await log.durations
        context.emit(["event": "result", "phase": "backlog", "images": count, "width": width, "height": height,
                      "png_mb": Double(pngBytes) / 1_048_576, "record_s": recordSeconds, "ocr_s": ocrSeconds, "pending_at_end": pending,
                      "recognized": durations.count, "empty": await log.empty, "characters": await log.characters,
                      "per_image_ms": percentiles(durations.sorted()), "peak_footprint_mb": peakFootprint, "peak_threads": peakThreads,
                      "panel_main_before_ms": baselineMain, "panel_ready_before_ms": baselineReady,
                      "panel_main_during_ms": percentiles(mainMs.sorted()), "panel_ready_during_ms": percentiles(readyMs.sorted()),
                      "main_stall_max_ms": stall].merging(after.delta(from: before)) { $1 })

        // 识别做完后静置，看内存和线程回落到多少。
        try await Task.sleep(for: .seconds(double("SETTLE", 10)))
        context.emit(["event": "result", "phase": "settled", "images": count, "width": width, "height": height].merging(Sample.now().absolute) { $1 })
    }

    // MARK: 数据

    /// 测量用的历史：多数是长短不一的中英文文本，夹着链接和小图片，来源分属几个应用，时间每条相隔一分钟。
    static func seed(_ store: HistoryStore, count: Int) throws {
        guard count > 0 else { return }
        var random = SeededRandom(seed: 1)
        let png = tinyPNG()
        let sources = [("com.apple.Safari", "Safari"), ("com.apple.dt.Xcode", "Xcode"), ("com.apple.Notes", "备忘录"),
                       ("com.apple.finder", "Finder"), ("com.apple.Terminal", "终端"), ("com.tinyspeck.slackmacgap", "Slack")]
        let base = Date().addingTimeInterval(-Double(count) * 60)
        for i in 0..<count {
            let rep: ClipRepresentation = switch i % 20 {
            case 0: ClipRepresentation(type: ClipType.png, data: png + Data("\(i)".utf8))
            case 1, 11: ClipRepresentation(type: ClipType.plainText, data: Data("https://example.com/bench/\(i)?q=\(random.next() % 1000)".utf8))
            default: ClipRepresentation(type: ClipType.plainText, data: Data(benchText(i, &random).utf8))
            }
            let source = sources[i % sources.count]
            try store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [rep])], sourceBundleID: source.0, sourceName: source.1),
                             now: base.addingTimeInterval(Double(i) * 60))
        }
    }

    private static let vocabulary = ["lorem", "ipsum", "XPaste", "quarterly", "report", "季度", "报告", "剪贴板", "测量", "function", "return",
                                     "let", "value", "数据", "历史", "search", "abstract", "的", "和", "build", "release", "设计", "评审", "a", "ab"]

    private static func benchText(_ index: Int, _ random: inout SeededRandom) -> String {
        let words = 1 + Int(random.next() % 60)
        return "条目 \(index) " + (0..<words).map { _ in vocabulary[Int(random.next() % UInt64(vocabulary.count))] }.joined(separator: " ")
    }

    private static func tinyPNG() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    /// 白底黑字、像截图一样排满文字的 PNG，每张的内容随序号不同（库里按内容去重）。
    private static func textPNG(width: Int, height: Int, index: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let fontSize = max(13, Double(height) / 60)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.black]
        var random = SeededRandom(seed: UInt64(index + 1))
        var y = Double(height) - fontSize * 2
        while y > fontSize {
            NSString(string: benchText(index, &random)).draw(at: NSPoint(x: fontSize, y: y), withAttributes: attributes)
            y -= fontSize * 1.5
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    /// 渐变加低位噪声的 PNG：压缩比接近真实照片和截图，大小随像素数增长。
    static func noisyPNG(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
        guard let pixels = rep.bitmapData else { return Data() }
        var random = SeededRandom(seed: UInt64(width * 31 + height))
        for y in 0..<height {
            let row = pixels + y * width * 4
            for x in 0..<width {
                let noise = UInt8(truncatingIfNeeded: random.next() & 0x1F)
                row[x * 4] = UInt8(truncatingIfNeeded: x * 255 / max(1, width - 1)) &+ noise
                row[x * 4 + 1] = UInt8(truncatingIfNeeded: y * 255 / max(1, height - 1)) &+ noise
                row[x * 4 + 2] = UInt8(truncatingIfNeeded: (x + y) & 0xFF) &+ noise
                row[x * 4 + 3] = 255
            }
        }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    // MARK: 输出

    static func emit(_ fields: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]),
              let line = String(data: data, encoding: .utf8) else { return }
        print("BENCH \(line)")
        fflush(stdout)
    }

    private static func percentiles(_ sorted: [Double]) -> [String: Double] {
        guard !sorted.isEmpty else { return [:] }
        func at(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))] }
        return ["p50": at(0.5), "p95": at(0.95), "max": sorted[sorted.count - 1], "min": sorted[0], "n": Double(sorted.count)]
    }

    private static func storageSizes(_ directory: URL) -> [String: Any] {
        func size(_ name: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path))?[.size] as? Int) ?? 0 }
        let assets = directory.appendingPathComponent("Assets")
        let files = (try? FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let assetBytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return ["db_bytes": size("db.sqlite"), "wal_bytes": size("db.sqlite-wal"), "asset_files": files.count, "asset_bytes": assetBytes]
    }
}

struct BenchError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// `ocr` 场景里每张图的识别用时和结果字数。
private actor RecognitionLog {
    private(set) var durations: [Double] = []
    private(set) var characters = 0
    private(set) var empty = 0

    func add(_ milliseconds: Double, characters count: Int) {
        durations.append(milliseconds)
        characters += count
        if count == 0 { empty += 1 }
    }
}

/// 可复现的伪随机数（xorshift），同一个种子每次生成相同的数据。
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func bytes(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            for i in 0..<count { buffer[i] = UInt8(truncatingIfNeeded: next()) }
        }
        return data
    }
}

/// 进程资源的一次取样。CPU 时间和唤醒次数取自 `proc_pid_rusage`，它在 Apple 芯片上以 mach 时间为单位，要换算成纳秒。
struct Sample {
    var cpuNs: UInt64 = 0
    var idleWakeups: UInt64 = 0
    var interruptWakeups: UInt64 = 0
    var diskRead: UInt64 = 0
    var diskWritten: UInt64 = 0
    var footprint: UInt64 = 0
    var threads = 0
    var fileDescriptors = 0
    var windows = 0
    var time = ContinuousClock.now

    var footprintMB: Double { Double(footprint) / 1_048_576 }

    @MainActor static func now() -> Sample {
        var sample = Sample()
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        if result == 0 {
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            sample.cpuNs = (info.ri_user_time + info.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
            sample.idleWakeups = info.ri_pkg_idle_wkups
            sample.interruptWakeups = info.ri_interrupt_wkups
            sample.diskRead = info.ri_diskio_bytesread
            sample.diskWritten = info.ri_diskio_byteswritten
            sample.footprint = info.ri_phys_footprint
        }
        var threads: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        if task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
            sample.threads = Int(count)
        }
        let bufferSize = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        if bufferSize > 0 {
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufferSize) / MemoryLayout<proc_fdinfo>.stride)
            let used = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, &fds, bufferSize)
            sample.fileDescriptors = Int(used) / MemoryLayout<proc_fdinfo>.stride
        }
        sample.windows = NSApp.windows.count
        return sample
    }

    var absolute: [String: Any] {
        ["footprint_mb": footprintMB, "threads": threads, "fds": fileDescriptors, "windows": windows]
    }

    /// 两次取样之间的差值，以及结束时的绝对值。
    func delta(from start: Sample) -> [String: Any] {
        let seconds = (time - start.time).seconds
        let cpu = Double(cpuNs - start.cpuNs) / 1e9
        let wakeups = (idleWakeups - start.idleWakeups) + (interruptWakeups - start.interruptWakeups)
        return absolute.merging([
            "window_s": seconds, "cpu_s": cpu, "cpu_pct_one_core": seconds > 0 ? cpu / seconds * 100 : 0,
            "wakeups": Int(wakeups), "wakeups_per_s": seconds > 0 ? Double(wakeups) / seconds : 0,
            "idle_wakeups": Int(idleWakeups - start.idleWakeups), "interrupt_wakeups": Int(interruptWakeups - start.interruptWakeups),
            "disk_read_bytes": Int(diskRead - start.diskRead), "disk_written_bytes": Int(diskWritten - start.diskWritten),
            "footprint_start_mb": start.footprintMB,
        ]) { $1 }
    }
}

/// 主线程心跳：每 4 ms 触发一次，记相邻两次之间的最大间隔，即这段时间里主线程最长被占住多久。
@MainActor
final class Heartbeat {
    private var timer: Timer?
    private var last = ContinuousClock.now
    private var maxGap: Duration = .zero

    func start() {
        timer?.invalidate()
        last = .now
        maxGap = .zero
        let timer = Timer(timeInterval: 0.004, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func beat() {
        let now = ContinuousClock.now
        maxGap = max(maxGap, now - last)
        last = now
    }

    /// 停止并返回最大间隔（毫秒）。结束时再算一次，覆盖最后一段还没触发的阻塞。
    func stop() -> Double {
        beat()
        timer?.invalidate()
        timer = nil
        return maxGap.milliseconds
    }
}

/// 每帧按实际经过的时间推进滚动位置，记录帧间隔。
@MainActor
final class ScrollDriver: NSObject {
    private let scrollView: NSScrollView
    private let speed: Double
    private var direction = 1.0
    private var lastTimestamp: CFTimeInterval?
    private(set) var intervals: [Double] = []
    private(set) var nominal = 1.0 / 60
    private(set) var reversals = 0

    init(scrollView: NSScrollView, speed: Double) {
        self.scrollView = scrollView
        self.speed = speed
    }

    @objc func step(_ link: CADisplayLink) {
        nominal = link.targetTimestamp - link.timestamp
        let elapsed = lastTimestamp.map { link.timestamp - $0 } ?? 0
        if lastTimestamp != nil { intervals.append(elapsed) }
        lastTimestamp = link.timestamp
        let clip = scrollView.contentView
        let maxX = max(0, (scrollView.documentView?.frame.width ?? 0) - clip.bounds.width)
        var x = clip.bounds.origin.x + direction * speed * elapsed
        if (direction > 0 && x >= maxX) || (direction < 0 && x <= 0) {
            x = min(max(x, 0), maxX)
            direction = -direction
            reversals += 1
        }
        clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
    var milliseconds: Double { seconds * 1_000 }
}
#endif
