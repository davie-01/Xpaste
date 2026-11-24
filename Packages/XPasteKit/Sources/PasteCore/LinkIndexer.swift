import Foundation

/// 后台给链接条目补页面标题和配图。一次只取一条，从最新的开始。
public actor LinkIndexer {
    /// 访问网页取回标题和配图。实际实现在应用层（LinkPresentation），测试里换成假的。
    public typealias Fetcher = @Sendable (URL) async throws -> LinkMetadata

    private let store: HistoryStore
    private let isEnabled: @Sendable () -> Bool
    private let fetch: Fetcher
    private let onChange: @Sendable () -> Void
    private var task: Task<Void, Never>?
    /// 这次运行里取失败的条目（多半是断网），不反复重试，留到下次启动。
    private var skipped: Set<Int64> = []

    /// `isEnabled` 对应“生成链接预览”开关，关着的时候不发任何请求。`onChange` 在某条链接的信息写入后调用。
    public init(store: HistoryStore, isEnabled: @escaping @Sendable () -> Bool = { true },
                onChange: @escaping @Sendable () -> Void = {}, fetch: @escaping Fetcher) {
        self.store = store
        self.isEnabled = isEnabled
        self.onChange = onChange
        self.fetch = fetch
    }

    /// 启动时和每次有新链接入库后调用。已经在处理就什么都不做，循环自己会取到新来的。
    public func kick() {
        guard task == nil, isEnabled() else { return }
        task = Task(priority: .utility) { await self.drain() }
    }

    /// 停止处理。正在取的那条不写结果，下次 `kick` 时重新取。
    public func cancel() {
        task?.cancel()
    }

    /// 开关变更：关闭取消正在取的内容；重新开启时等旧任务退出再补未完成项。
    public func settingsDidChange() async {
        guard isEnabled() else { cancel(); return }
        if let task, task.isCancelled { await task.value }
        kick()
    }

    /// 等当前这一轮处理结束。测试用。
    public func waitUntilIdle() async {
        await task?.value
    }

    private func drain() async {
        while !Task.isCancelled, isEnabled(), let job = try? store.nextLinkAwaitingMetadata(excluding: skipped) {
            guard let url = LinkPolicy.fetchableURL(job.url) else {
                // 本机、内网地址或不是 http(s)：不访问，以后也不再看它。
                _ = try? store.setLinkMetadata(nil, for: job)
                continue
            }
            do {
                let metadata = try await fetch(url)
                if Task.isCancelled || !isEnabled() { break }
                // 取的过程中条目被删的话，这里什么都不会写。
                if (try? store.setLinkMetadata(metadata, for: job)) == true { onChange() }
            } catch is CancellationError {
                break
            } catch {
                // 系统 provider 取消时可能抛 LPError，而不是 CancellationError。
                if Task.isCancelled || !isEnabled() { break }
                skipped.insert(job.id)
            }
        }
        // 上面判断“没有待处理的了”和这里清空之间没有挂起点，不会漏掉刚好这时到来的 kick。
        task = nil
    }
}
