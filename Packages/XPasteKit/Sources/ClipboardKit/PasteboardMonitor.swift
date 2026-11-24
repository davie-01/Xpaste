import AppKit

/// 轮询 changeCount 的采集器。未变化的 tick 只读计数，不读 payload。
/// 读内容放在后台串行队列：写入方迟迟不给延迟提供的数据时，读取会一直等（实测等满 120 秒也不超时，R26），
/// 放在主线程上整个界面都会卡住。同一时刻只有一个读取，卡住期间的新复制等它结束后再读。
@MainActor
public final class PasteboardMonitor {
    public var policy = CapturePolicy() {
        didSet {
            guard oldValue != policy else { return }
            // 设置变更取消旧策略下尚未完成的读取，不补采当前剪贴板。
            cancelRetry()
            readToken &+= 1
            observedCount = pasteboard.changeCount
        }
    }
    public var onCapture: ((ClipSnapshot) -> Void)?
    public var onSkip: ((CapturePolicy.SkipReason) -> Void)?
    /// 取采集时刻的来源应用；默认用前台应用。
    public var sourceProvider: () -> ClipSource = {
        let app = NSWorkspace.shared.frontmostApplication
        return ClipSource(bundleID: app?.bundleIdentifier, name: app?.localizedName)
    }

    /// 用户多久没有操作键盘鼠标算“离开”。离开期间轮询放慢到 `idleInterval`，一有操作马上恢复（轻量化：空闲唤醒从每秒 4 次降到 1 次）。
    /// 不会漏记：剪贴板计数一直在累加，只是离开后的第一次复制最多晚 `idleInterval` 才读到。设为 nil 时不放慢（测量和测试用）。
    public var idleAfter: TimeInterval? = 60
    public var idleInterval: TimeInterval = 1
    /// 距离上次键盘鼠标操作的秒数。测试可以替换。
    public var secondsSinceUserInput: () -> TimeInterval = {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    public private(set) var isRunning = false
    public private(set) var isPaused = false

    private let pasteboard: NSPasteboard
    private let interval: TimeInterval
    private var timer: Timer?
    private var observedCount: Int
    /// 计数先变、数据后到时的重试：同一 generation 最多重试这么多次。
    private let retryDelays: [TimeInterval] = [0.05, 0.1, 0.2]
    private var retryIndex = 0
    private var retryTask: Task<Void, Never>?
    private let readQueue = DispatchQueue(label: "XPaste.pasteboard-read", qos: .userInitiated)
    /// 改设置、暂停、停止时加一，正在进行的读取回来后看到序号变了就丢弃结果。
    private var readToken = 0
    private var readInFlight = false
    private var settleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(pasteboard: NSPasteboard = .general, interval: TimeInterval = 0.25) {
        self.pasteboard = pasteboard
        self.interval = interval
        self.observedCount = pasteboard.changeCount
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        observedCount = pasteboard.changeCount
        if !isPaused { startTimer() }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        stopTimer()
        cancelRetry()
        readToken &+= 1
    }

    /// 暂停与恢复都把已观察计数对齐到当前值：暂停期间的复制不补录。暂停期间计时器停掉，不再每 250 毫秒唤醒（审查：轮询）。
    public func setPaused(_ paused: Bool) {
        isPaused = paused
        cancelRetry()
        readToken &+= 1
        observedCount = pasteboard.changeCount
        if paused { stopTimer() } else if isRunning { startTimer() }
    }

    /// 计时器在跑（测试用）。
    public var isPolling: Bool { timer?.isValid == true }

    /// 当前计时器的间隔（测试用）。
    public private(set) var currentInterval: TimeInterval = 0

    private func startTimer(interval: TimeInterval? = nil) {
        guard timer == nil else { return }
        let interval = interval ?? self.interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.adjustCadence()
                self?.tick()
            }
        }
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        currentInterval = interval
    }

    /// 按用户是否离开调整轮询间隔；只有间隔真的要变时才重建计时器。
    public func adjustCadence() {
        guard timer != nil else { return }
        let away = idleAfter.map { secondsSinceUserInput() >= $0 } ?? false
        let wanted = away ? max(idleInterval, interval) : interval
        guard wanted != currentInterval else { return }
        stopTimer()
        startTimer(interval: wanted)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// 自己写回剪贴板后调用，避免把这次计数变化当成新复制去读。
    public func acknowledge(changeCount: Int) {
        observedCount = max(observedCount, changeCount)
    }

    public func tick() {
        guard !isPaused, !readInFlight else { return }
        let count = pasteboard.changeCount
        guard count != observedCount else { return }
        observedCount = count
        cancelRetry()
        read(generation: count)
    }

    /// 等正在进行的读取结束、结果交付完。测试和测量在 `tick()` 之后调用。
    public func settle() async {
        guard readInFlight else { return }
        await withCheckedContinuation { settleWaiters.append($0) }
    }

    private func read(generation: Int) {
        // 来源取发起读取这一刻的前台应用。
        let policy = policy, source = sourceProvider(), token = readToken
        nonisolated(unsafe) let pasteboard = pasteboard
        readInFlight = true
        readQueue.async { [weak self] in
            let result = PasteboardReader.read(from: pasteboard, policy: policy, source: source)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishRead(result, generation: generation, token: token) }
            }
        }
    }

    private func finishRead(_ result: PasteboardReadResult, generation: Int, token: Int) {
        readInFlight = false
        defer {
            let waiters = settleWaiters
            settleWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        guard token == readToken else { return }
        switch result {
        case .snapshot(let snapshot):
            onCapture?(snapshot)
        case .skipped(let reason):
            onSkip?(reason)
        case .changedDuringRead:
            // 下一个 tick 会看到新的计数并重新读取；期间自己写过剪贴板（计数已被确认到更新的值）就不回拨。
            if observedCount == generation { observedCount = generation - 1 }
        case .notReady:
            scheduleRetry(generation: generation)
        }
    }

    private func scheduleRetry(generation: Int) {
        guard retryIndex < retryDelays.count else { return }
        let delay = retryDelays[retryIndex]
        retryIndex += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            guard !self.isPaused, !self.readInFlight, self.pasteboard.changeCount == generation else { return }
            self.read(generation: generation)
        }
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
        retryIndex = 0
    }
}
