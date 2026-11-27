import ClipboardKit
import Foundation
import Network
import Testing
@testable import MCPBridge
@testable import MCPKit
@testable import PasteCore

private let port: UInt16 = 39999
private let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAEElEQVR4nGP4z8DwHwQZYAwAR8oH+Rq28akAAAAASUVORK5CYII=")!

private func text(_ value: String, app: String? = nil) -> ClipSnapshot {
    ClipSnapshot(items: [ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.plainText, data: Data(value.utf8))])],
                 sourceBundleID: app.map { "com.example.\($0.lowercased())" }, sourceName: app)
}

/// 批准结果可控的假确认框，并记下被问过几次。
private actor FakeApprover {
    var answer = true
    private(set) var asked: [String] = []
    func set(_ value: Bool) { answer = value }
    func ask(_ name: String) -> Bool { asked.append(name); return answer }
}

/// 记下 `add_items_to_stack` 交给应用的条目。
private final class StackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[Int64]] = []
    func record(_ ids: [Int64]) { lock.withLock { calls.append(ids) } }
    var recorded: [[Int64]] { lock.withLock { calls } }
}

/// 测试用的临时目录：最后一个持有者释放时删掉，测试不在系统临时目录里留数据。
private final class TemporaryDirectory: Sendable {
    let url: URL

    init(_ prefix: String) {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

private struct Harness {
    let directory = TemporaryDirectory("xpaste-mcp")
    let store: HistoryStore
    let stack = StackRecorder()
    let clients: MCPClientStore
    let server: MCPServer
    let approver = FakeApprover()

    init(clientsURL: URL? = nil) throws {
        store = try HistoryStore(directory: directory.url)
        clients = MCPClientStore(url: clientsURL)
        let approver = approver
        let stack = stack
        server = MCPServer(port: port, clients: clients, store: store, approver: { await approver.ask($0) },
                           sourceBundleID: "com.mars.XPaste", sourceName: "XPaste", deviceName: "Test Mac",
                           onStack: { stack.record($0) })
    }

    func request(_ method: String, _ path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) async -> HTTPResponse {
        await server.handle(HTTPRequest(method: method, path: path, query: query,
                                        headers: ["Host": "127.0.0.1:\(port)"].merging(headers) { $1 }, body: body))
    }

    func json(_ response: HTTPResponse) -> JSONValue { JSONValue.parse(response.body) ?? .null }

    /// 走完一次 OAuth：注册、打开授权页、等确认框的结果、换令牌。批准时返回令牌。
    func authorize(name: String = "Claude Code", verifier: String = "verifier-0123456789-abcdefghijklmnopqrstuvwxyz") async throws -> (token: String?, redirect: String) {
        let registered = json(await request("POST", "/register", body: Data(#"{"client_name":"\#(name)","redirect_uris":["http://localhost:5555/callback"]}"#.utf8)))
        let clientID = try #require(registered["client_id"]?.string)
        let page = await request("GET", "/authorize", query: [
            "response_type": "code", "client_id": clientID, "redirect_uri": "http://localhost:5555/callback",
            "code_challenge": MCPServer.challenge(for: verifier), "code_challenge_method": "S256", "state": "s1",
        ])
        #expect(page.status == 200)
        let html = String(decoding: page.body, as: UTF8.self)
        // 页面里不能有可以直接提交的批准表单。
        #expect(!html.contains("<form") && !html.contains("<button"))
        let requestID = try #require(html.range(of: #"request=([A-Za-z0-9_-]+)"#, options: .regularExpression)
            .map { String(html[$0].dropFirst("request=".count)) })
        var location = ""
        for _ in 0..<50 {
            let status = await request("GET", "/authorize/wait", query: ["request": requestID])
            if status.status == 302 { location = status.headers["Location"] ?? ""; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let items = URLComponents(string: location)?.queryItems ?? []
        #expect(items.first { $0.name == "state" }?.value == "s1")
        guard let code = items.first(where: { $0.name == "code" })?.value else { return (nil, location) }
        let form = "grant_type=authorization_code&code=\(code)&client_id=\(clientID)&redirect_uri=http%3A%2F%2Flocalhost%3A5555%2Fcallback&code_verifier=\(verifier)"
        let token = json(await request("POST", "/token", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(form.utf8)))
        return (token["access_token"]?.string, location)
    }

    func rpc(_ token: String?, session: String?, _ method: String, params: JSONValue? = nil, id: Int? = 1) async -> HTTPResponse {
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let id { message["id"] = .int(id) }
        if let params { message["params"] = params }
        var headers: [String: String] = [:]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        if let session { headers["MCP-Session-Id"] = session }
        return await request("POST", "/mcp", headers: headers, body: JSONValue.object(message).encoded())
    }

    func connect() async throws -> (token: String, session: String) {
        let token = try #require(try await authorize().token)
        let initialize = await rpc(token, session: nil, "initialize", params: ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]])
        return (token, try #require(initialize.headers["MCP-Session-Id"]))
    }

    /// 调用工具，返回 (结果, 是否出错, 第一段文本)。
    func call(_ connection: (token: String, session: String), _ name: String, _ arguments: JSONValue = [:]) async -> (result: JSONValue, isError: Bool, text: String) {
        let response = json(await rpc(connection.token, session: connection.session, "tools/call", params: ["name": .string(name), "arguments": arguments]))
        let result = response["result"] ?? .null
        let text: String
        if case .array(let content) = result["content"] ?? .null, let first = content.first?["text"]?.string { text = first } else { text = "" }
        return (result["structuredContent"] ?? .null, result["isError"]?.bool ?? true, text)
    }
}

@Suite struct HTTPParsingTests {
    @Test func parsesRequestWithBodyAndQuery() throws {
        let raw = Data("POST /token?a=1&b=x%20y HTTP/1.1\r\nHost: 127.0.0.1:39999\r\nContent-Length: 5\r\n\r\nhello".utf8)
        guard case .complete(let request) = HTTPRequest.parse(raw) else { Issue.record("not parsed"); return }
        #expect(request.method == "POST" && request.path == "/token" && request.query == ["a": "1", "b": "x y"])
        #expect(request.headers["host"] == "127.0.0.1:39999" && request.body == Data("hello".utf8))
    }

    @Test func waitsForTheWholeBodyAndRejectsChunked() {
        let partial = Data("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nhal".utf8)
        guard case .incomplete = HTTPRequest.parse(partial) else { Issue.record("should wait"); return }
        let chunked = Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        guard case .invalid(501) = HTTPRequest.parse(chunked) else { Issue.record("chunked accepted"); return }
        let huge = Data("POST / HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n".utf8)
        guard case .invalid(413) = HTTPRequest.parse(huge) else { Issue.record("oversized accepted"); return }
    }

    @Test func decodesForms() {
        #expect(HTTPRequest.decodeForm("a=1&b=x+y&c=%2F") == ["a": "1", "b": "x y", "c": "/"])
    }
}

@Suite struct MCPAuthorizationTests {
    @Test func noTokenMeansNoAccessAndPointsToMetadata() async throws {
        let h = try Harness()
        let response = await h.rpc(nil, session: nil, "initialize")
        #expect(response.status == 401)
        #expect(response.headers["WWW-Authenticate"]?.contains("/.well-known/oauth-protected-resource") == true)
        #expect(await h.rpc("made-up-token", session: nil, "tools/list").status == 401)
        let metadata = h.json(await h.request("GET", "/.well-known/oauth-authorization-server"))
        #expect(metadata["code_challenge_methods_supported"] == ["S256"])
        #expect(h.json(await h.request("GET", "/.well-known/oauth-protected-resource"))["resource"] == "http://127.0.0.1:39999/mcp")
    }

    @Test func approvalHappensOnlyInTheApp() async throws {
        let h = try Harness()
        let (token, _) = try await h.authorize(name: "Claude Code")
        #expect(token != nil)
        #expect(await h.approver.asked == ["Claude Code"])
        #expect(h.clients.connectedClients.map(\.name) == ["Claude Code"])
    }

    @Test func deniedApprovalRedirectsWithAccessDenied() async throws {
        let h = try Harness()
        await h.approver.set(false)
        let (token, location) = try await h.authorize()
        #expect(token == nil && location.contains("error=access_denied"))
        #expect(h.clients.connectedClients.isEmpty)
    }

    @Test func pkceAndSingleUseCodes() async throws {
        let h = try Harness()
        let registered = h.json(await h.request("POST", "/register", body: Data(#"{"client_name":"X","redirect_uris":["http://127.0.0.1:1/cb"]}"#.utf8)))
        let clientID = try #require(registered["client_id"]?.string)
        let page = String(decoding: await h.request("GET", "/authorize", query: [
            "response_type": "code", "client_id": clientID, "redirect_uri": "http://127.0.0.1:1/cb",
            "code_challenge": MCPServer.challenge(for: "right-verifier"), "code_challenge_method": "S256",
        ]).body, as: UTF8.self)
        let requestID = String(page[page.range(of: #"request=[A-Za-z0-9_-]+"#, options: .regularExpression)!].dropFirst(8))
        var location = ""
        for _ in 0..<50 where location.isEmpty {
            location = await h.request("GET", "/authorize/wait", query: ["request": requestID]).headers["Location"] ?? ""
            try await Task.sleep(for: .milliseconds(10))
        }
        let code = try #require(URLComponents(string: location)?.queryItems?.first { $0.name == "code" }?.value)
        func exchange(_ verifier: String) async -> HTTPResponse {
            await h.request("POST", "/token", body: Data("grant_type=authorization_code&code=\(code)&client_id=\(clientID)&redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fcb&code_verifier=\(verifier)".utf8))
        }
        #expect(await exchange("wrong-verifier").status == 400)
        // 校验失败后授权码也作废，不能再试。
        #expect(await exchange("right-verifier").status == 400)
    }

    @Test func registrationRejectsRemoteRedirects() async throws {
        let h = try Harness()
        let response = await h.request("POST", "/register", body: Data(#"{"client_name":"Evil","redirect_uris":["http://evil.example/cb"]}"#.utf8))
        #expect(response.status == 400)
    }

    @Test func revokeTakesEffectImmediately() async throws {
        let h = try Harness()
        let connection = try await h.connect()
        #expect(await h.rpc(connection.token, session: connection.session, "tools/list").status == 200)
        let client = try #require(h.clients.connectedClients.first)
        try h.clients.revoke(clientID: client.id)
        #expect(await h.rpc(connection.token, session: connection.session, "tools/list").status == 401)
        // 通过 OAuth 撤销端点同样立即失效。
        let second = try await h.connect()
        _ = await h.request("POST", "/revoke", body: Data("token=\(second.token)".utf8))
        #expect(await h.rpc(second.token, session: second.session, "tools/list").status == 401)
    }

    @Test func rejectsForeignHostAndOrigin() async throws {
        let h = try Harness()
        let rebinding = await h.server.handle(HTTPRequest(method: "GET", path: "/.well-known/oauth-authorization-server", headers: ["Host": "evil.example:39999"]))
        #expect(rebinding.status == 403)
        let crossSite = await h.request("POST", "/register", headers: ["Origin": "https://evil.example"], body: Data("{}".utf8))
        #expect(crossSite.status == 403)
    }

    @Test func clientStorePersistsHashesOnly() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xpaste-mcp-clients-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let h = try Harness(clientsURL: url)
        let token = try #require(try await h.authorize().token)
        let saved = try String(contentsOf: url, encoding: .utf8)
        #expect(!saved.contains(token) && saved.contains(MCPClientStore.hash(token)))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        let reloaded = MCPClientStore(url: url)
        #expect(reloaded.authenticate(token: token)?.name == "Claude Code")
        let manual = try reloaded.createManualClient(name: "Script")
        #expect(reloaded.authenticate(token: manual.token)?.id == manual.client.id)
    }

    /// 并发授予和撤销后，文件里的状态与内存一致：旧状态不会晚写、盖过新状态（审查 02）。
    @Test func concurrentChangesPersistInOrder() async throws {
        for round in 0..<20 {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("xpaste-mcp-order-\(round)-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            let clients = MCPClientStore(url: url)
            let created = try (0..<32).map { try clients.createManualClient(name: "c\($0)").client.id }
            await withTaskGroup(of: Void.self) { group in
                for id in created { group.addTask { _ = try? clients.revoke(clientID: id) } }
                for index in 0..<8 { group.addTask { _ = try? clients.createManualClient(name: "n\(index)") } }
            }
            let inMemory = Set(clients.connectedClients.map(\.id))
            let onDisk = Set(MCPClientStore(url: url).connectedClients.map(\.id))
            #expect(inMemory == onDisk)
            #expect(inMemory.isDisjoint(with: created) && inMemory.count == 8)
        }
    }

    /// 写不进文件时：新建的连接不留下、不交出令牌；撤销在内存里照样生效，同时报错（审查 02）。
    @Test func writeFailuresAreReported() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xpaste-mcp-fail-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let clients = MCPClientStore(url: url)
        let kept = try clients.createManualClient(name: "Kept")
        let pending = clients.register(name: "OAuth", redirectURIs: ["http://localhost/cb"])
        clients.debugWriteFailure = CocoaError(.fileWriteNoPermission)
        #expect(throws: CocoaError.self) { try clients.createManualClient(name: "Lost") }
        #expect(clients.connectedClients.map(\.id) == [kept.client.id])
        #expect(clients.issueToken(for: pending.id) == nil)
        #expect(clients.client(id: pending.id)?.isConnected == false)
        #expect(throws: CocoaError.self) { try clients.revoke(clientID: kept.client.id) }
        #expect(clients.authenticate(token: kept.token) == nil)
        clients.debugWriteFailure = nil
        // 文件里还是撤销前的状态：这正是要提示用户的情况。
        #expect(MCPClientStore(url: url).connectedClients.map(\.id) == [kept.client.id])
    }

    @Test func pendingRegistrationsAreCappedAndExpire() throws {
        let clients = MCPClientStore(url: nil)
        let stale = clients.register(name: "stale", redirectURIs: ["http://localhost/cb"], now: Date().addingTimeInterval(-2 * 24 * 3600))
        for index in 0..<50 { _ = clients.register(name: "c\(index)", redirectURIs: ["http://localhost/cb"]) }
        // 本机程序反复注册也不会无限增长；过期的注册被清掉。
        #expect(clients.count == MCPClientStore.maxPendingRegistrations)
        #expect(clients.client(id: stale.id) == nil)
        // 已连接的客户端不受上限影响。
        let manual = try clients.createManualClient(name: "Kept")
        for index in 0..<30 { _ = clients.register(name: "d\(index)", redirectURIs: ["http://localhost/cb"]) }
        #expect(clients.client(id: manual.client.id) != nil)
    }
}

@Suite struct MCPSessionTests {
    @Test func sessionsAreRequiredAndScopedToTheClient() async throws {
        let h = try Harness()
        let first = try await h.connect()
        #expect(await h.rpc(first.token, session: nil, "tools/list").status == 400)
        #expect(await h.rpc(first.token, session: "unknown", "tools/list").status == 404)
        let second = try await h.connect()
        // 别的客户端的会话不能用。
        #expect(await h.rpc(second.token, session: first.session, "tools/list").status == 404)
        #expect(await h.rpc(first.token, session: first.session, "notifications/initialized", id: nil).status == 202)
        _ = await h.request("DELETE", "/mcp", headers: ["Authorization": "Bearer \(first.token)", "MCP-Session-Id": first.session])
        #expect(await h.rpc(first.token, session: first.session, "tools/list").status == 404)
    }

    @Test func negotiatesProtocolVersionAndListsTwelveTools() async throws {
        let h = try Harness()
        let token = try #require(try await h.authorize().token)
        let old = h.json(await h.rpc(token, session: nil, "initialize", params: ["protocolVersion": "2025-06-18"]))
        #expect(old["result"]?["protocolVersion"] == "2025-06-18")
        let unknown = await h.rpc(token, session: nil, "initialize", params: ["protocolVersion": "1999-01-01"])
        #expect(h.json(unknown)["result"]?["protocolVersion"] == "2025-11-25")
        let session = try #require(unknown.headers["MCP-Session-Id"])
        guard case .array(let tools) = h.json(await h.rpc(token, session: session, "tools/list"))["result"]?["tools"] ?? .null else {
            Issue.record("no tools"); return
        }
        #expect(Set(tools.compactMap { $0["name"]?.string }) == ["search", "read_item", "list_pinboards", "create_item", "update_item",
            "delete_item", "add_item_to_pinboard", "remove_item_from_pinboard", "create_pinboard", "rename_pinboard", "delete_pinboard",
            "add_items_to_stack"])
        #expect(h.json(await h.rpc(token, session: session, "nope"))["error"]?["code"] == -32601)
    }
}

@Suite struct MCPToolTests {
    /// 按给出的顺序交给应用；有一个 id 不存在就整个拒绝，什么都不加。
    @Test func addItemsToStack() async throws {
        let h = try Harness()
        let c = try await h.connect()
        let first = try #require(await h.call(c, "create_item", ["content": "first"]).result["id"]?.string)
        let second = try #require(await h.call(c, "create_item", ["content": "second"]).result["id"]?.string)
        let added = await h.call(c, "add_items_to_stack", ["item_ids": [.string(second), .string(first)]])
        #expect(!added.isError && added.result["added"] == 2)
        let ids = try h.store.clips(limit: 2)
        #expect(h.stack.recorded == [[ids[0].id, ids[1].id]])
        #expect(await h.call(c, "add_items_to_stack", ["item_ids": [.string(first), "nope"]]).isError)
        #expect(await h.call(c, "add_items_to_stack", ["item_ids": []]).isError)
        #expect(await h.call(c, "add_items_to_stack", [:]).isError)
        #expect(h.stack.recorded.count == 1)
    }

    @Test func createSearchAndReadText() async throws {
        let h = try Harness()
        let c = try await h.connect()
        let created = await h.call(c, "create_item", ["content": "  hello from claude  "])
        #expect(!created.isError && created.result["type"] == "text" && created.result["app"] == "XPaste")
        let id = try #require(created.result["id"]?.string)
        #expect(await h.call(c, "read_item", ["id": .string(id)]).text == "  hello from claude  ")
        let found = await h.call(c, "search", ["query": "claude"])
        #expect(found.result["items"]?.encoded() == JSONValue.array([created.result]).encoded())
        #expect(await h.call(c, "create_item", ["content": "#ff0000"]).result["type"] == "color")
        #expect(await h.call(c, "create_item", ["content": "https://example.com/a"]).result["type"] == "link")
        let empty = await h.call(c, "create_item", ["content": "   "])
        #expect(empty.isError && empty.text.contains("needs some text"))
    }

    @Test func searchFilters() async throws {
        let h = try Harness()
        let c = try await h.connect()
        try h.store.record(text("from notes", app: "Notes"), now: Date(timeIntervalSince1970: 1_700_000_000))
        try h.store.record(text("from mail", app: "Mail"), now: Date(timeIntervalSince1970: 1_800_000_000))
        // 来源应用按名称或 bundle ID 匹配，不区分大小写。
        for app in ["Notes", "notes", "com.example.notes"] {
            guard case .array(let notes) = await h.call(c, "search", ["app": .string(app)]).result["items"] ?? .null else { Issue.record("search \(app)"); return }
            #expect(notes.count == 1 && notes[0]["preview"] == "from notes", "\(app)")
        }
        guard case .array(let recent) = await h.call(c, "search", ["date_from": "2025-01-01"]).result["items"] ?? .null else { return }
        #expect(recent.map { $0["preview"] } == ["from mail"])
        guard case .array(let none) = await h.call(c, "search", ["device": "Other Mac"]).result["items"] ?? .null else { return }
        #expect(none.isEmpty)
        let limited = await h.call(c, "search", ["limit": 1])
        #expect(limited.result["hasMore"] == true)
        #expect(await h.call(c, "search", ["date_from": "2030-01-01", "date_to": "2020-01-01"]).isError)
        #expect(await h.call(c, "search", ["type": "video"]).isError)
    }

    @Test func pinboardTools() async throws {
        let h = try Harness()
        let c = try await h.connect()
        let board = await h.call(c, "create_pinboard", ["name": "  Work  "])
        #expect(board.result["name"] == "Work" && board.result["itemCount"] == 0)
        let boardID = try #require(board.result["id"]?.string)
        #expect(await h.call(c, "rename_pinboard", ["id": .string(boardID), "name": "Projects"]).result["name"] == "Projects")
        let item = try #require(await h.call(c, "create_item", ["content": "in history"]).result["id"]?.string)
        #expect(await h.call(c, "add_item_to_pinboard", ["item_id": .string(item), "pinboard_id": .string(boardID)]).result["itemCount"] == 1)
        // 幂等：再固定一次不变。
        #expect(await h.call(c, "add_item_to_pinboard", ["item_id": .string(item), "pinboard_id": .string(boardID)]).result["itemCount"] == 1)
        #expect(await h.call(c, "remove_item_from_pinboard", ["item_id": .string(item), "pinboard_id": .string(boardID)]).result["itemCount"] == 0)
        #expect(try h.store.summary(uuid: item)?.timestamp != nil)

        // 直接建在 Pinboard 里的只固定、不进历史；不能单纯取消固定（那会删掉它）。
        let pinnedOnly = await h.call(c, "create_item", ["content": "only pinned", "list_id": .string(boardID)])
        #expect(pinnedOnly.result["timestamp"] == nil && pinnedOnly.result["pinboard_id"]?.string == boardID)
        let pinnedID = try #require(pinnedOnly.result["id"]?.string)
        #expect(await h.call(c, "remove_item_from_pinboard", ["item_id": .string(pinnedID), "pinboard_id": .string(boardID)]).isError)
        guard case .array(let pinboards) = await h.call(c, "list_pinboards").result["pinboards"] ?? .null else { return }
        #expect(pinboards.count == 1 && pinboards[0]["itemCount"] == 1)
        #expect(await h.call(c, "search", ["pinboard_id": .string(boardID)]).result["items"].map { if case .array(let a) = $0 { a.count } else { 0 } } == 1)
        // 历史里已有的内容建到 Pinboard 时固定已有条目，不重复。
        let again = await h.call(c, "create_item", ["content": "in history", "list_id": .string(boardID)])
        #expect(again.result["id"]?.string == item && again.result["timestamp"] != nil)

        let preview = await h.call(c, "delete_pinboard", ["id": .string(boardID)])
        #expect(!preview.isError && preview.text.hasPrefix("Dry run") && preview.text.contains("1 of them are kept only here"))
        #expect(try h.store.pinboards().count == 1)
        let deleted = await h.call(c, "delete_pinboard", ["id": .string(boardID), "confirm": true])
        #expect(deleted.result["deletedItems"] == 1)
        #expect(try h.store.pinboards().isEmpty)
        #expect(try h.store.summary(uuid: item) != nil)
        #expect(try h.store.summary(uuid: pinnedID) == nil)
    }

    @Test func updateAndTwoStepDelete() async throws {
        let h = try Harness()
        let c = try await h.connect()
        let id = try #require(await h.call(c, "create_item", ["content": "draft"]).result["id"]?.string)
        let updated = await h.call(c, "update_item", ["id": .string(id), "title": "Title", "content": "https://example.com"])
        #expect(updated.result["title"] == "Title" && updated.result["type"] == "link" && updated.result["id"]?.string == id)
        #expect(await h.call(c, "update_item", ["id": .string(id), "title": ""]).result["title"] == nil)
        #expect(await h.call(c, "update_item", ["id": .string(id)]).isError)
        let image = try h.store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.png, data: tinyPNG)])]))
        let rejected = await h.call(c, "update_item", ["id": .string(image.uuid), "content": "x"])
        #expect(rejected.isError && rejected.text.contains("only `title` can be changed"))

        let preview = await h.call(c, "delete_item", ["id": .string(id)])
        #expect(!preview.isError && preview.text.hasPrefix("Dry run"))
        #expect(try h.store.summary(uuid: id) != nil)
        #expect(await h.call(c, "delete_item", ["id": .string(id), "confirm": true]).result["deleted"] == true)
        #expect(try h.store.summary(uuid: id) == nil)
        let missing = await h.call(c, "read_item", ["id": .string(id)])
        #expect(missing.isError && missing.text.contains("get ids from search"))
    }

    @Test func readsImagesColorsAndFiles() async throws {
        let h = try Harness()
        let c = try await h.connect()
        let image = try h.store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.png, data: tinyPNG)])]))
        let response = h.json(await h.rpc(c.token, session: c.session, "tools/call", params: ["name": "read_item", "arguments": ["id": .string(image.uuid)]]))
        guard case .array(let content) = response["result"]?["content"] ?? .null else { Issue.record("no content"); return }
        #expect(content.first?["type"] == "image" && content.first?["mimeType"] == "image/png")
        let color = try h.store.record(text("3366cc"))
        #expect(await h.call(c, "read_item", ["id": .string(color.uuid)]).text == "#3366CC")
        let files = try h.store.record(ClipSnapshot(items: ["/tmp/a.txt", "/tmp/b c.txt"].map {
            ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.fileURL, data: Data(URL(fileURLWithPath: $0).absoluteString.utf8))])
        }))
        #expect(await h.call(c, "read_item", ["id": .string(files.uuid)]).text == "/tmp/a.txt\n/tmp/b c.txt")
    }

    @Test func parsesDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let start = try MCPTools.parseDate("2026-05-01", field: "f", end: false, calendar: calendar)
        let end = try MCPTools.parseDate("2026-05-01", field: "f", end: true, calendar: calendar)
        #expect(end.timeIntervalSince(start) == 24 * 3600)
        #expect(try MCPTools.parseDate("2026-05-01T00:00:00Z", field: "f", end: false) == Date(timeIntervalSince1970: 1_777_593_600))
        #expect(try MCPTools.parseDate("2026-05-01T00:00:00.500Z", field: "f", end: false).timeIntervalSince1970 == 1_777_593_600.5)
        #expect(throws: ToolError.self) { try MCPTools.parseDate("2026-02-30", field: "f", end: false) }
        #expect(throws: ToolError.self) { try MCPTools.parseDate("yesterday", field: "f", end: false) }
    }
}

@Suite struct MCPNetworkTests {
    /// 真实监听：只在 127.0.0.1 上可连，停止后连接被拒。
    @Test func listensOnLoopbackOnlyAndStops() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xpaste-mcp-net-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(directory: directory)
        var service: MCPService?
        var bound: UInt16 = 0
        for _ in 0..<10 {
            let candidate = UInt16.random(in: 49_152...65_000)
            let attempt = MCPService(server: MCPServer(port: candidate, clients: MCPClientStore(url: nil), store: store, approver: { _ in false }))
            if let port = try? await attempt.start() { service = attempt; bound = port; break }
        }
        let running = try #require(service)
        let metadata = URL(string: "http://127.0.0.1:\(bound)/.well-known/oauth-authorization-server")!
        let (data, response) = try await URLSession.shared.data(from: metadata)
        #expect((response as? HTTPURLResponse)?.statusCode == 200 && JSONValue.parse(data)?["issuer"]?.string == "http://127.0.0.1:\(bound)")
        let unauthorized = try await URLSession.shared.data(for: {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(bound)/mcp")!)
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            return request
        }())
        #expect((unauthorized.1 as? HTTPURLResponse)?.statusCode == 401)
        // 没有监听 IPv6 回环。
        await #expect(throws: (any Error).self) { _ = try await URLSession.shared.data(from: URL(string: "http://[::1]:\(bound)/")!) }
        // 同一端口再启动一个服务：报告端口被占用，而不是含糊的系统错误。
        let second = MCPService(server: MCPServer(port: bound, clients: MCPClientStore(url: nil), store: store, approver: { _ in false }))
        await #expect(throws: LoopbackHTTPServer.StartError.addressInUse) { _ = try await second.start() }
        running.stop()
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: (any Error).self) { _ = try await URLSession.shared.data(from: metadata) }
    }
}

@Suite struct MCPStdioBridgeTests {
    @Test func rejectsMissingOrInvalidConfiguration() {
        #expect(throws: MCPStdioBridge.ConfigurationError.missingURL) { try MCPStdioBridge(environment: ["MCP_TOKEN": "t"]) }
        #expect(throws: MCPStdioBridge.ConfigurationError.invalidURL) { try MCPStdioBridge(environment: ["MCP_URL": "file:///tmp/x", "MCP_TOKEN": "t"]) }
        #expect(throws: MCPStdioBridge.ConfigurationError.missingToken) { try MCPStdioBridge(environment: ["MCP_URL": "http://127.0.0.1:1/mcp"]) }
    }

    /// 经真实端口转发：初始化后自动带会话号，通知没有输出，错误令牌给出可读的 JSON-RPC 错误。
    @Test func forwardsLinesOverHTTP() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xpaste-mcp-bridge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(directory: directory)
        let clients = MCPClientStore(url: nil)
        var service: MCPService?
        var bound: UInt16 = 0
        for _ in 0..<10 {
            let candidate = UInt16.random(in: 49_152...65_000)
            let attempt = MCPService(server: MCPServer(port: candidate, clients: clients, store: store, approver: { _ in false }))
            if let port = try? await attempt.start() { service = attempt; bound = port; break }
        }
        let running = try #require(service)
        defer { running.stop() }
        let token = try clients.createManualClient(name: "stdio").token
        let bridge = try MCPStdioBridge(environment: ["MCP_URL": "http://127.0.0.1:\(bound)/mcp", "MCP_TOKEN": token])
        let initialize = try #require(await bridge.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#))
        #expect(JSONValue.parse(Data(initialize.utf8))?["result"]?["serverInfo"]?["name"] == "xpaste")
        #expect(await bridge.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let tools = try #require(await bridge.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        #expect(tools.contains("\"read_item\"") && !tools.contains("\n"))
        let created = try #require(await bridge.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"create_item","arguments":{"content":"via stdio"}}}"#))
        #expect(created.contains("via stdio"))
        await bridge.close()

        let wrong = try MCPStdioBridge(environment: ["MCP_URL": "http://127.0.0.1:\(bound)/mcp", "MCP_TOKEN": "wrong"])
        let rejected = try #require(await wrong.handle(line: #"{"jsonrpc":"2.0","id":9,"method":"initialize"}"#))
        #expect(JSONValue.parse(Data(rejected.utf8))?["error"]?["code"] == -32001)
        #expect(JSONValue.parse(Data(rejected.utf8))?["id"] == 9)
    }
}

/// 回环服务的连接管理（审查 06）：半截请求到期断开，连接数有上限，启动中停止不会变成成功。
@Suite struct LoopbackServerLimitTests {
    private func connect(_ port: UInt16) async -> NWConnection? {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let ready: Bool = await withCheckedContinuation { continuation in
            nonisolated(unsafe) var done = false
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if !done { done = true; continuation.resume(returning: true) }
                // 端口上没有监听时连接停在 .waiting（被拒绝），不会自己变成 .failed。
                case .failed, .cancelled, .waiting: if !done { done = true; continuation.resume(returning: false) }
                default: break
                }
            }
            connection.start(queue: .global())
        }
        return ready ? connection : nil
    }

    /// 等对方关闭连接（读到 EOF 或出错），最多等 `seconds` 秒。
    private func closedByServer(_ connection: NWConnection, within seconds: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            nonisolated(unsafe) var done = false
            let lock = NSLock()
            func finish(_ value: Bool) { lock.withLock { if !done { done = true; continuation.resume(returning: value) } } }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, isComplete, error in
                if isComplete || error != nil { finish(true) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { finish(false) }
        }
    }

    @Test func incompleteRequestsAreClosedAfterTheDeadline() async throws {
        let server = LoopbackHTTPServer { _ in HTTPResponse(status: 200) }
        server.requestDeadline = 0.3
        let port = try await server.start(port: 0)
        defer { server.stop() }
        let connection = try #require(await connect(port))
        connection.send(content: Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n".utf8), completion: .idempotent)
        #expect(await closedByServer(connection, within: 3))
        connection.cancel()
    }

    @Test func connectionsBeyondTheLimitAreRefused() async throws {
        let server = LoopbackHTTPServer { _ in HTTPResponse(status: 200) }
        server.maxConnections = 2
        let port = try await server.start(port: 0)
        defer { server.stop() }
        var open: [NWConnection] = []
        for _ in 0..<2 { open.append(try #require(await connect(port))) }
        try await Task.sleep(for: .milliseconds(200))
        let extra = try #require(await connect(port))
        #expect(await closedByServer(extra, within: 3))
        // 前两个仍然开着。
        #expect(await closedByServer(open[0], within: 0.3) == false)
        (open + [extra]).forEach { $0.cancel() }
    }

    @Test func stoppingDuringStartDoesNotLeaveAListener() async throws {
        let server = LoopbackHTTPServer { _ in HTTPResponse(status: 200) }
        let started = Task { try await server.start(port: 0) }
        server.stop()
        let port = try? await started.value
        server.stop()
        try await Task.sleep(for: .milliseconds(200))
        // 不管启动是否赶在停止之前完成，最后都不应再有监听。
        if let port { #expect(await connect(port) == nil) }
    }
}
