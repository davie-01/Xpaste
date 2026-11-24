import Foundation

/// 后台给图片条目补文字识别结果，写进搜索索引。一次只处理一张，从最新的开始。
public actor OCRIndexer {
    /// 把图像数据识别成文字。实际实现在应用层（Vision），测试里换成假的。
    public typealias Recognizer = @Sendable (Data) async throws -> String

    private let store: HistoryStore
    private let recognize: Recognizer
    private var task: Task<Void, Never>?

    public init(store: HistoryStore, recognize: @escaping Recognizer) {
        self.store = store
        self.recognize = recognize
    }

    /// 启动时和每次有新图片入库后调用。已经在处理就什么都不做，循环自己会取到新来的。
    public func kick() {
        guard task == nil else { return }
        task = Task(priority: .utility) { await self.drain() }
    }

    /// 停止处理。正在识别的那张不写结果，下次 `kick` 时重新识别。
    public func cancel() {
        task?.cancel()
    }

    /// 等当前这一轮处理结束。测试用。
    public func waitUntilIdle() async {
        await task?.value
    }

    private func drain() async {
        while !Task.isCancelled, let job = try? store.nextImageAwaitingOCR() {
            guard let data = try? store.imageData(id: job.id) else {
                // 读不出图像（外置文件丢了等），标成失败，免得每次都卡在这一张上。
                _ = try? store.setOCRResult(nil, for: job)
                continue
            }
            do {
                let text = try await recognize(data)
                if Task.isCancelled { break }
                // 识别期间条目被删的话，这里什么都不会写。
                _ = try? store.setOCRResult(text, for: job)
            } catch is CancellationError {
                break
            } catch {
                _ = try? store.setOCRResult(nil, for: job)
            }
        }
        // 上面判断“没有待处理的了”和这里清空之间没有挂起点，不会漏掉刚好这时到来的 kick。
        task = nil
    }
}
