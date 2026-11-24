import Foundation

/// 给只支持 stdio 的 AI 工具用：每行一条 JSON-RPC 消息，转发到 XPaste 的 HTTP 服务，把响应写回一行。
/// 读 `MCP_URL` 与 `MCP_TOKEN`，自己记住 `MCP-Session-Id`。
public actor MCPStdioBridge {
    public enum ConfigurationError: LocalizedError {
        case missingURL, invalidURL, missingToken
        public var errorDescription: String? {
            switch self {
            case .missingURL: "set MCP_URL to the server address shown in XPaste settings"
            case .invalidURL: "MCP_URL has to start with http:// or https://"
            case .missingToken: "set MCP_TOKEN to a token created in XPaste settings"
            }
        }
    }

    let url: URL
    let token: String
    private let session: URLSession
    private var sessionID: String?
    private var protocolVersion: String?

    public init(environment: [String: String], session: URLSession = .shared) throws {
        guard let value = environment["MCP_URL"], !value.isEmpty else { throw ConfigurationError.missingURL }
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw ConfigurationError.invalidURL
        }
        guard let token = environment["MCP_TOKEN"], !token.isEmpty else { throw ConfigurationError.missingToken }
        self.url = url
        self.token = token
        self.session = session
    }

    /// 处理一行输入。通知没有响应时返回 nil；失败时把错误包成 JSON-RPC 错误回给客户端。
    public func handle(line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let message = JSONValue.parse(Data(trimmed.utf8))
        let id = message?["id"]
        guard let message, message.object != nil else { return Self.error(id: nil, code: -32700, "Parse error") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(trimmed.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id") }
        if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }

        let data: Data
        let response: HTTPURLResponse
        do {
            let (body, raw) = try await session.data(for: request)
            guard let http = raw as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            data = body
            response = http
        } catch {
            return id.map { Self.error(id: $0, code: -32000, "Cannot reach XPaste: \(error.localizedDescription)") } ?? nil
        }

        if message["method"]?.string == "initialize", let new = response.value(forHTTPHeaderField: "MCP-Session-Id") {
            sessionID = new
            protocolVersion = JSONValue.parse(Self.jsonBody(data, response))?["result"]?["protocolVersion"]?.string
        }
        switch response.statusCode {
        case 200:
            let body = Self.jsonBody(data, response)
            return body.isEmpty ? nil : String(decoding: body, as: UTF8.self)
        case 202: return nil
        case 401: return id.map { Self.error(id: $0, code: -32001, "XPaste rejected the token. Create a new token in XPaste Settings › MCP & AI Tools.") } ?? nil
        case 404:
            sessionID = nil
            return id.map { Self.error(id: $0, code: -32001, "The XPaste session ended. Restart the MCP server in your AI tool.") } ?? nil
        default: return id.map { Self.error(id: $0, code: -32000, "XPaste returned HTTP \(response.statusCode)") } ?? nil
        }
    }

    /// 退出时结束会话。
    public func close() async {
        guard let sessionID else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
        _ = try? await session.data(for: request)
        self.sessionID = nil
    }

    /// 服务端可能用 SSE 回复：取出最后一条 data 消息。
    static func jsonBody(_ data: Data, _ response: HTTPURLResponse) -> Data {
        guard response.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true else { return data }
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        return lines.last { $0.hasPrefix("data: {") }.map { Data($0.dropFirst(6).utf8) } ?? Data()
    }

    static func error(id: JSONValue?, code: Int, _ message: String) -> String {
        String(decoding: JSONValue.object(["jsonrpc": "2.0", "id": id ?? .null, "error": ["code": .int(code), "message": .string(message)]]).encoded(),
               as: UTF8.self)
    }
}
