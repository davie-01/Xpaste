#if DEBUG
import Foundation
import MCPKit
import PasteCore

/// R37 的自检：默认不监听；无令牌被拒；手动令牌可用；断开后立即被拒；停止后端口关闭。用独立临时库与随机端口。
@MainActor
enum MCPSelfTest {
    static func run(preferences: AppPreferences, check: (String, Bool, String) -> Void) async throws {
        check("识别语言默认简繁中文与英文，且都在系统支持列表中", {
            let supported = Set(TextRecognition.supportedLanguages.map(\.id))
            return preferences.recognitionLanguages.count == 3 && preferences.recognitionLanguages.allSatisfy(supported.contains)
                && !preferences.recognitionAutoDetect
        }(), "")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xpaste-mcp-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(directory: directory)
        let clients = MCPClientStore(url: directory.appendingPathComponent("mcp-clients.json"))
        var service: MCPService?
        var port: UInt16 = 0
        for _ in 0..<10 {
            let candidate = UInt16.random(in: 49_152...65_000)
            let attempt = MCPService(server: MCPServer(port: candidate, clients: clients, store: store, approver: { _ in false }))
            if let bound = try? await attempt.start() { service = attempt; port = bound; break }
        }
        guard let service else { check("MCP 自检有可用端口", false, ""); return }
        let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
        func post(_ body: String, token: String?, session: String? = nil) async -> (Int, String?, Data) {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if let session { request.setValue(session, forHTTPHeaderField: "MCP-Session-Id") }
            guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else { return (0, nil, Data()) }
            return (http.statusCode, http.value(forHTTPHeaderField: "MCP-Session-Id"), data)
        }
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#
        check("MCP 无令牌请求被拒", await post(initialize, token: nil).0 == 401, "")
        guard let manual = try? clients.createManualClient(name: "自检") else { check("手动连接能创建", false, ""); return }
        let opened = await post(initialize, token: manual.token)
        let listed = await post(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, token: manual.token, session: opened.1)
        check("MCP 手动令牌可初始化并列出 12 个工具", opened.0 == 200 && listed.0 == 200
              && String(decoding: listed.2, as: UTF8.self).components(separatedBy: "\"inputSchema\"").count == 13, "")
        try? clients.revoke(clientID: manual.client.id)
        check("MCP 断开后令牌立即失效", await post(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#, token: manual.token, session: opened.1).0 == 401, "")
        let saved = (try? String(contentsOf: directory.appendingPathComponent("mcp-clients.json"), encoding: .utf8)) ?? ""
        check("MCP 客户端文件不含令牌明文", !saved.contains(manual.token), "")
        service.stop()
        try await Task.sleep(for: .milliseconds(100))
        check("MCP 停止后端口不再接受连接", await post(initialize, token: nil).0 == 0, "")
        // 偏好域放在本测试的临时目录里，随目录删除（原因见 SelfTest 中的设置测试）
        let defaults = UserDefaults(suiteName: directory.appendingPathComponent("mcp-defaults").path)!
        check("MCP 偏好默认关闭", !AppPreferences(defaults: defaults).mcpEnabled, "")
    }
}
#endif
