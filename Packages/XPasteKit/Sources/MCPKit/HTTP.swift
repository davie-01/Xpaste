import Foundation
import Network

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// 键一律小写。
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
        self.body = body
    }

    /// `application/x-www-form-urlencoded` 的请求体。
    public var form: [String: String] { Self.decodeForm(String(decoding: body, as: UTF8.self)) }

    static func decodeForm(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            if let key = parts.first, !key.isEmpty { result[key] = parts.count > 1 ? parts[1] : "" }
        }
        return result
    }

    enum ParseResult {
        case incomplete
        case invalid(status: Int)
        case complete(HTTPRequest)
    }

    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 4 * 1024 * 1024

    /// 只支持带 Content-Length 的请求体；分块传输直接拒绝。
    static func parse(_ data: Data) -> ParseResult {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeaderBytes ? .invalid(status: 431) : .incomplete
        }
        guard end.lowerBound <= maxHeaderBytes,
              let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid(status: 431) }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid(status: 400) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(status: 400) }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .invalid(status: 501) }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid(status: 400) }
        guard length <= maxBodyBytes else { return .invalid(status: 413) }
        let bodyStart = end.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<data.index(bodyStart, offsetBy: length)]
        let target = String(requestLine[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .complete(HTTPRequest(method: String(requestLine[0]), path: components?.path ?? target, query: query,
                                     headers: headers, body: Data(body)))
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func json(_ value: JSONValue, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers.merging(["Content-Type": "application/json"]) { $1 }, body: value.encoded())
    }

    static func html(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: [
            "Content-Type": "text/html; charset=utf-8",
            // 页面不需要脚本和外部资源。
            "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'",
            "Cache-Control": "no-store",
        ], body: Data(text.utf8))
    }

    static func redirect(_ location: String) -> HTTPResponse {
        HTTPResponse(status: 302, headers: ["Location": location, "Cache-Control": "no-store"])
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var headers = headers
        headers["Content-Length"] = String(body.count)
        headers["Connection"] = "close"
        headers["Server"] = "XPasteMCP"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 302: "Found"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        case 431: "Request Header Fields Too Large"
        case 501: "Not Implemented"
        default: "Error"
        }
    }
}

/// 只绑定 127.0.0.1 的 HTTP/1.1 服务。每个连接处理一个请求后关闭。
public final class LoopbackHTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    public enum StartError: LocalizedError, Equatable {
        /// 端口已被其他程序占用。
        case addressInUse
        case failed(String)
        public var errorDescription: String? {
            switch self {
            case .addressInUse: "Address already in use"
            case .failed(let message): message
            }
        }
        static func from(_ error: NWError) -> StartError {
            if case .posix(.EADDRINUSE) = error { return .addressInUse }
            return .failed(error.localizedDescription)
        }
    }

    private let queue = DispatchQueue(label: "XPaste.MCP.HTTP")
    private let handler: Handler
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// 还没收齐请求的连接。超过 `requestDeadline` 仍没收齐就断开，免得半截请求一直占着连接（审查 06）。
    private var reading: Set<ObjectIdentifier> = []
    /// 每次 stop() 加一（只在 `queue` 上读写）。start() 把监听挂上之前先核对：期间被停过就直接取消，不留下监听。
    private var generation = 0

    /// 同时最多这么多个连接，多出来的直接断开。本机的 AI 工具通常只有几个。测试可以调小。
    var maxConnections = 32
    var requestDeadline: TimeInterval = 30
    /// 监听迟迟既不就绪也不失败时，启动按失败处理。
    static let startDeadline: TimeInterval = 5

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// 端口为 0 时由系统分配（测试用）。返回实际端口。
    public func start(port: UInt16) async throws -> UInt16 {
        let attempt = queue.sync { generation }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do { listener = try NWListener(using: parameters) }
        catch { throw StartError.failed(error.localizedDescription) }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: listener.port?.rawValue ?? port)
                case .failed(let error), .waiting(let error):
                    listener.cancel()
                    guard !resumed else { return }
                    resumed = true
                    self?.listener = nil
                    continuation.resume(throwing: StartError.from(error))
                case .cancelled:
                    // 启动中被 stop() 取消：结束等待，不再当成启动成功。
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(throwing: StartError.failed("Cancelled"))
                default: break
                }
            }
            queue.async {
                guard self.generation == attempt else {
                    // 还没开始监听就被停了。
                    resumed = true
                    continuation.resume(throwing: StartError.failed("Cancelled"))
                    return
                }
                self.listener = listener
                listener.start(queue: self.queue)
            }
            queue.asyncAfter(deadline: .now() + Self.startDeadline) {
                guard !resumed else { return }
                resumed = true
                listener.cancel()
                if self.listener === listener { self.listener = nil }
                continuation.resume(throwing: StartError.failed("Timed out"))
            }
        }
    }

    /// 停止监听并断开全部连接。
    public func stop() {
        queue.sync {
            generation += 1
            listener?.cancel()
            listener = nil
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < maxConnections else {
            connection.cancel()
            return
        }
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        reading.insert(key)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections[key] = nil
                self?.reading.remove(key)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
        queue.asyncAfter(deadline: .now() + requestDeadline) { [weak self] in
            guard let self, self.reading.contains(key) else { return }
            connection.cancel()
        }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil { connection.cancel() } else { self.receive(on: connection, buffer: buffer) }
            case .invalid(let status):
                self.reading.remove(ObjectIdentifier(connection))
                self.send(HTTPResponse(status: status), on: connection)
            case .complete(let request):
                self.reading.remove(ObjectIdentifier(connection))
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    self.queue.async { self.send(response, on: connection) }
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
    }
}
