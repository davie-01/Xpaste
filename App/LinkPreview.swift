import AppKit
import PasteCore

/// 取网页标题和配图。不用系统的 LinkPresentation：它自己跟随跳转、自己加载配图，中途去了内网地址也拦不住（L11）。
/// 这里每一次请求和每一次跳转都先确认目标解析到公网地址，再从 HTML 里取标题、配图和站点图标。
enum LinkMetadataFetcher {
    static func fetch(_ url: URL) async throws -> PasteCore.LinkMetadata {
        let fetcher = PublicOnlyFetcher()
        defer { fetcher.invalidate() }
        let (data, response) = try await fetcher.get(url, limit: 1_000_000)
        guard response.mimeType.map({ $0.contains("html") }) ?? true else { throw URLError(.cannotParseResponse) }
        let metadata = HTMLMetadata(html: Self.decode(data, response), baseURL: response.url ?? url)
        var result = PasteCore.LinkMetadata(title: metadata.title)
        // 页面自带的配图优先，没有再用站点图标；每种最多试三个地址。
        for (candidates, kind) in [(metadata.images, LinkImageKind.image), (metadata.icons, .icon)] {
            for candidate in candidates.prefix(3) {
                try Task.checkCancellation()
                guard let (data, _) = try? await fetcher.get(candidate, limit: 5_000_000), let png = await pngData(data) else { continue }
                result.image = png
                result.imageKind = kind
                return result
            }
        }
        return result
    }

    /// 按响应头或页面里声明的编码解出文字，都没有就当 UTF-8。
    private static func decode(_ data: Data, _ response: URLResponse) -> String {
        var encoding: String.Encoding?
        if let name = response.textEncodingName { encoding = Self.encoding(named: name) }
        if encoding == nil, let head = String(data: data.prefix(4_096), encoding: .isoLatin1),
           let match = head.range(of: #"charset\s*=\s*["']?([A-Za-z0-9_-]+)"#, options: [.regularExpression, .caseInsensitive]) {
            let name = head[match].split(separator: "=").last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) } ?? ""
            encoding = Self.encoding(named: name)
        }
        return String(data: data, encoding: encoding ?? .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private static func encoding(named name: String) -> String.Encoding? {
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// 统一转成 PNG，最长边不超过 `maxPixel`（审查 13）：在后台用 ImageIO 按缩略图解码，大图不会整张解开占内存，也不占主线程。
    /// ImageIO 解不了的（SVG 站点图标等）才回到主线程用 NSImage，且只处理 512 KB 以内的数据。
    static let maxPixel = 1_024

    private static func pngData(_ data: Data) async -> Data? {
        let decoded = await Task.detached(priority: .utility) { () -> Data? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                  ] as CFDictionary) else { return nil }
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }.value
        if let decoded { return decoded }
        guard data.count <= 512 * 1024 else { return nil }
        return await vectorPNGData(data)
    }

    @MainActor
    private static func vectorPNGData(_ data: Data) -> Data? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        // 矢量图没有像素尺寸，按 256 的边长栅格化。
        let pixels = image.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
        let scale = pixels > 0 ? 1 : 256 / max(image.size.width, image.size.height)
        var rect = NSRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    /// 网址写法是公开网址、而且域名现在解析出的每个地址都是公网地址。网页预览加载前和每次跳转前也用它（L100）。
    static func isPublicURL(_ url: URL) async -> Bool {
        guard LinkPolicy.fetchableURL(url.absoluteString) != nil, let host = url.host(percentEncoded: false) else { return false }
        return await resolvesToPublicAddresses(host)
    }

    /// 域名解析出的每个地址都是公网地址才放行；解析失败也不放行。
    static func resolvesToPublicAddresses(_ host: String) async -> Bool {
        await Task.detached(priority: .utility) {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return false }
            defer { freeaddrinfo(list) }
            var found = false
            for info in sequence(first: first, next: { $0.pointee.ai_next }) {
                var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
                let address = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                guard LinkPolicy.isPublicAddress(address) else { return false }
                found = true
            }
            return found
        }.value
    }

    #if DEBUG
    /// 自检用：放行这一个本机地址作为第一跳，用来确认它之后的跳转仍会被拦下。
    nonisolated(unsafe) static var debugAllowedFirstHop: URL?
    #endif
}

/// 只访问公网地址的 HTTP 客户端：不带 cookie 和缓存，每次跳转前重新检查目标，响应体有大小上限。
private final class PublicOnlyFetcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.httpAdditionalHeaders = [
            // 有些网站只给像浏览器的请求返回带元信息的页面。
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            "Accept-Language": Locale.preferredLanguages.prefix(3).joined(separator: ", "),
        ]
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func get(_ url: URL, limit: Int) async throws -> (Data, URLResponse) {
        guard await Self.isAllowed(url, firstHop: true) else { throw URLError(.unsupportedURL) }
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        // 检查时解析的地址和系统真正连接时解析的可能不同（DNS rebinding）：看实际连上的地址，是本机或内网就丢掉结果（L100）。
        guard await connectedToPublicAddresses(bytes.task) else { throw URLError(.unsupportedURL) }
        return (data, response)
    }

    func invalidate() { session.invalidateAndCancel() }

    // MARK: 实际连接的地址

    private let lock = NSLock()
    private var metrics: [Int: URLSessionTaskMetrics] = [:]
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        self.metrics[task.taskIdentifier] = metrics
        let waiter = waiters.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        waiter?.resume()
    }

    /// 这次请求经过的每个连接都连到公网地址。走代理的连接不看（连的是代理本身，域名由代理解析）。
    /// 读到了内容却拿不到连接记录时不放行。
    private func connectedToPublicAddresses(_ task: URLSessionTask) async -> Bool {
        if task.state == .running { task.cancel() } // 读够上限就停，不再接收剩下的内容。
        let id = task.taskIdentifier
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.resumeWaiter(id)
        }
        defer { timeout.cancel() }
        await withCheckedContinuation { continuation in
            lock.lock()
            if metrics[id] != nil {
                lock.unlock()
                continuation.resume()
            } else {
                waiters[id] = continuation
                lock.unlock()
            }
        }
        let collected = lock.withLock { metrics.removeValue(forKey: id) }
        guard let transactions = collected?.transactionMetrics.filter({ $0.response != nil }), !transactions.isEmpty else { return false }
        return transactions.allSatisfy { transaction in
            if transaction.isProxyConnection { return true }
            guard let address = transaction.remoteAddress else { return false }
            return LinkPolicy.isPublicAddress(address)
        }
    }

    private func resumeWaiter(_ id: Int) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        lock.unlock()
        waiter?.resume()
    }

    // 跳转目标同样要是公网地址，否则停在这里，不发出下一个请求。
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, await Self.isAllowed(url, firstHop: false) else { return nil }
        return request
    }

    private static func isAllowed(_ url: URL, firstHop: Bool) async -> Bool {
        #if DEBUG
        if firstHop, let allowed = LinkMetadataFetcher.debugAllowedFirstHop, allowed == url { return true }
        #endif
        return await LinkMetadataFetcher.isPublicURL(url)
    }
}

extension NSWorkspace {
    /// 打开这个地址的默认应用的名称（“Safari浏览器”）。
    func defaultApplicationName(for url: URL) -> String? {
        urlForApplication(toOpen: url).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
    }
}
