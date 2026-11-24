import CryptoKit
import Foundation

/// 一个 AI 工具。通过 OAuth 注册、尚未获批的只有注册信息；获批或手动创建后才有令牌。
public struct MCPClient: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable { case oauth, manual }

    public let id: String
    public var name: String
    public var kind: Kind
    public var redirectURIs: [String]
    public var createdAt: Date
    /// 令牌的 SHA-256；不保存令牌本身。
    var tokenHash: String?
    public var connectedAt: Date?
    public var lastUsedAt: Date?

    public var isConnected: Bool { tokenHash != nil }
}

/// 客户端与令牌的持久化。每个客户端只有一个有效令牌；撤销即删除整条记录。
public final class MCPClientStore: @unchecked Sendable {
    /// 未获批的注册最多保留这么多条、这么久，避免本机程序反复注册把文件撑大。
    static let maxPendingRegistrations = 20
    static let pendingRegistrationLifetime: TimeInterval = 24 * 3600
    /// 最近使用时间按分钟级精度落盘，避免每个请求都写文件。
    static let lastUsedWriteInterval: TimeInterval = 60

    private let url: URL?
    /// 保护内存里的列表。
    private let lock = NSLock()
    /// 串行化“改内存 + 写文件”：先改的先写，旧状态不会盖过新状态（审查 02）。拿锁顺序总是先它再 `lock`。
    private let writeLock = NSLock()
    private var clients: [MCPClient] = []
    private let onChange: @Sendable () -> Void

    /// `url` 为 nil 时只存在内存里（测试用）。
    public init(url: URL?, onChange: @escaping @Sendable () -> Void = {}) {
        self.url = url
        self.onChange = onChange
        if let url, let data = try? Data(contentsOf: url) {
            clients = (try? Self.decoder.decode([MCPClient].self, from: data)) ?? []
        }
    }

    /// 已获得令牌的客户端，供设置页显示。
    public var connectedClients: [MCPClient] {
        lock.withLock { clients.filter(\.isConnected).sorted { $0.createdAt < $1.createdAt } }
    }

    /// 全部记录数（含未获批的注册）。
    var count: Int { lock.withLock { clients.count } }

    func client(id: String) -> MCPClient? {
        lock.withLock { clients.first { $0.id == id } }
    }

    func register(name: String, redirectURIs: [String], now: Date = Date()) -> MCPClient {
        let client = MCPClient(id: UUID().uuidString, name: name, kind: .oauth, redirectURIs: redirectURIs, createdAt: now)
        // 未获批的注册写不进文件也无妨：只影响重启后还认不认这次注册。
        try? mutate(rollbackOnFailure: false) { clients in
            clients.removeAll { !$0.isConnected && now.timeIntervalSince($0.createdAt) > Self.pendingRegistrationLifetime }
            let pending = clients.filter { !$0.isConnected }
            if pending.count >= Self.maxPendingRegistrations, let oldest = pending.min(by: { $0.createdAt < $1.createdAt }) {
                clients.removeAll { $0.id == oldest.id }
            }
            clients.append(client)
        }
        return client
    }

    /// 为客户端签发新令牌，旧令牌随之失效。返回令牌明文，只此一次。
    /// 随机源失败或写不进文件时不签发（内存也退回原状）：重启后不认的令牌不该交出去。
    func issueToken(for clientID: String, now: Date = Date()) -> String? {
        guard let token = try? Self.randomToken() else { return nil }
        var issued = false
        let saved = try? mutate(rollbackOnFailure: true) { clients in
            guard let index = clients.firstIndex(where: { $0.id == clientID }) else { return }
            clients[index].tokenHash = Self.hash(token)
            clients[index].connectedAt = now
            clients[index].lastUsedAt = now
            issued = true
        }
        return issued && saved != nil ? token : nil
    }

    /// 手动连接（手填 URL + 令牌）。返回客户端与令牌明文。写不进文件时抛错，不留下这个客户端。
    public func createManualClient(name: String, now: Date = Date()) throws -> (client: MCPClient, token: String) {
        let token = try Self.randomToken()
        let client = MCPClient(id: UUID().uuidString, name: name, kind: .manual, redirectURIs: [], createdAt: now,
                               tokenHash: Self.hash(token), connectedAt: now, lastUsedAt: nil)
        try mutate(rollbackOnFailure: true) { $0.append(client) }
        return (client, token)
    }

    /// 校验令牌，成功时更新最近使用时间并返回客户端。
    func authenticate(token: String, now: Date = Date()) -> MCPClient? {
        let hash = Self.hash(token)
        var found: MCPClient?
        var persist = false
        lock.withLock {
            guard let index = clients.firstIndex(where: { $0.tokenHash == hash }) else { return }
            if now.timeIntervalSince(clients[index].lastUsedAt ?? .distantPast) >= Self.lastUsedWriteInterval { persist = true }
            clients[index].lastUsedAt = now
            found = clients[index]
        }
        if persist {
            writeLock.withLock { try? write(lock.withLock { clients }) }
            onChange()
        }
        return found
    }

    /// 撤销：删除整条记录，令牌立即失效。
    /// 内存里总是立即生效；写不进文件时抛错，让界面告诉用户重启后可能恢复连接。返回是否真的删掉了记录。
    @discardableResult
    public func revoke(clientID: String) throws -> Bool {
        var removed = false
        try mutate(rollbackOnFailure: false) { clients in
            let before = clients.count
            clients.removeAll { $0.id == clientID }
            removed = clients.count != before
        }
        return removed
    }

    func revoke(token: String) throws {
        let hash = Self.hash(token)
        try mutate(rollbackOnFailure: false) { $0.removeAll { $0.tokenHash == hash } }
    }

    /// 改端口时断开全部客户端。
    public func removeAll() throws { try mutate(rollbackOnFailure: false) { $0.removeAll() } }

    /// 改内存并写文件，整个过程按调用顺序串行。写失败时：授予类的改动退回原状（`rollbackOnFailure`），
    /// 撤销类的改动保留在内存里（令牌立即失效更重要），都把错误抛给调用方。
    private func mutate(rollbackOnFailure: Bool, _ change: (inout [MCPClient]) -> Void) throws {
        defer { onChange() }
        try writeLock.withLock {
            let (before, after) = lock.withLock { () -> ([MCPClient], [MCPClient]) in
                let before = clients
                change(&clients)
                return (before, clients)
            }
            guard before != after else { return }
            do {
                try write(after)
            } catch {
                if rollbackOnFailure { lock.withLock { clients = before } }
                throw error
            }
        }
    }

    /// 只在持有 `writeLock` 时调用。
    private func write(_ clients: [MCPClient]) throws {
        guard let url else { return }
        #if DEBUG
        if let failure = debugWriteFailure { throw failure }
        #endif
        let data = try Self.encoder.encode(clients)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        // 只允许本用户读写。
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    #if DEBUG
    /// 测试用：让写文件失败。
    nonisolated(unsafe) var debugWriteFailure: Error?
    #endif

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    struct RandomSourceError: Error {}

    static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw RandomSourceError() }
        return Data(bytes).base64URLEncoded
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
