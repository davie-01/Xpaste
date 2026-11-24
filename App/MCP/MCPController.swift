import AppKit
import MCPKit
import PasteCore

/// 按偏好启停 MCP 服务，并在应用里弹出连接确认。设置页（第 8 步）通过这里读写客户端和端口。
@MainActor
final class MCPController {
    let clients: MCPClientStore
    private let store: HistoryStore
    private let preferences: AppPreferences
    private var service: MCPService?
    /// 正在启动、还没就绪的服务。启动期间关掉开关或换端口时，它会被停掉，不会回头变成活动服务（审查 06）。
    private var starting: MCPService?
    /// 每次启动或停止加一；启动等待结束时代数变了，说明设置在这期间改过，结果作废。
    private var generation = 0
    /// 最近一次启动失败的原因（如端口被占用）；正常运行时为空。
    private(set) var lastError: String?
    /// MCP 改动了历史或 Pinboard。
    var onHistoryChange: () -> Void = {}
    /// 连接列表或最近使用时间变化。
    var onClientsChange: () -> Void = {}
    /// MCP 要把这些条目加进 Stack。
    var onStack: ([Int64]) -> Void = { _ in }

    init(store: HistoryStore, directory: URL, preferences: AppPreferences = .shared) {
        self.store = store
        self.preferences = preferences
        nonisolated(unsafe) var notify: (() -> Void)?
        clients = MCPClientStore(url: directory.appendingPathComponent("mcp-clients.json")) {
            Task { @MainActor in notify?() }
        }
        notify = { [weak self] in self?.onClientsChange() }
    }

    var isRunning: Bool { service != nil }
    var endpointURL: String { "http://127.0.0.1:\(preferences.mcpPort)/mcp" }

    /// 按当前偏好启动或停止。关闭时不监听任何端口。
    func apply() async {
        guard preferences.mcpEnabled else {
            stop()
            return
        }
        guard service == nil, starting == nil else { return }
        generation += 1
        let attempt = generation
        let port = preferences.mcpPort
        let server = MCPServer(port: preferences.mcpPort, clients: clients, store: store,
                               approver: { name in await MCPController.askApproval(clientName: name) },
                               sourceBundleID: Bundle.main.bundleIdentifier, sourceName: "XPaste",
                               pinboardColors: PanelController.pinboardColors,
                               serverVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
                               onChange: { [weak self] in Task { @MainActor in self?.onHistoryChange() } },
                               onStack: { [weak self] ids in Task { @MainActor in self?.onStack(ids) } })
        let candidate = MCPService(server: server)
        starting = candidate
        do {
            _ = try await candidate.start()
            guard attempt == generation, preferences.mcpEnabled, preferences.mcpPort == port else {
                // 启动期间设置变了：这次的结果不用。
                candidate.stop()
                return
            }
            starting = nil
            service = candidate
            lastError = nil
        } catch {
            guard attempt == generation else { return }
            starting = nil
            lastError = (error as? LoopbackHTTPServer.StartError) == .addressInUse
                ? String(localized: "端口 \(String(port)) 已被其他程序占用。")
                : String(localized: "端口 \(String(port)) 无法使用：\(error.localizedDescription)")
            Log.mcp.error("MCP 服务启动失败（端口 \(port)）: \(String(describing: error))")
        }
    }

    func stop() {
        generation += 1
        starting?.stop()
        starting = nil
        service?.stop()
        service = nil
    }

    /// 改端口：已连接的 AI 工具记着旧地址，全部断开，需要重新连接。新端口用不了时退回原端口，连接保留，返回原因。
    func setPort(_ port: UInt16) async -> String? {
        let old = preferences.mcpPort
        guard port != old else { return nil }
        stop()
        preferences.mcpPort = port
        if preferences.mcpEnabled {
            await apply()
            if let error = lastError {
                preferences.mcpPort = old
                lastError = nil
                await apply()
                return error
            }
        }
        do { try clients.removeAll() } catch {
            return String(localized: "已断开所有 AI 工具，但没能保存到文件，重启 XPaste 后它们可能恢复连接：\(error.localizedDescription)")
        }
        return nil
    }

    /// 转接程序与应用放在一起（Contents/MacOS）。
    var bridgePath: String {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("xpaste-mcp-stdio").path ?? "xpaste-mcp-stdio"
    }

    /// 断开一个 AI 工具：令牌和会话立即失效。写不进文件时返回原因（重启后这个连接可能恢复）。
    func disconnect(clientID: String) async -> String? {
        var failure: String?
        do { try clients.revoke(clientID: clientID) } catch {
            failure = String(localized: "已断开，但没能保存到文件，重启 XPaste 后这个连接可能恢复：\(error.localizedDescription)")
        }
        await service?.server.endSessions(clientID: clientID)
        return failure
    }

    /// 连接只能在这里批准；浏览器页面只提示到 XPaste 确认。默认按钮是“拒绝”，避免误按回车放行。
    nonisolated static func askApproval(clientName: String) async -> Bool {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = String(localized: "允许“\(clientName)”连接 XPaste？")
            alert.informativeText = String(localized: "连接后，它可以搜索和读取你的剪贴板历史，新建、修改和删除条目，并管理 Pinboard。只有你刚在这个 AI 工具里发起连接时才应允许。之后可以在设置中断开。")
            alert.addButton(withTitle: String(localized: "拒绝"))
            alert.addButton(withTitle: String(localized: "允许"))
            WindowSharing.apply(to: alert.window)
            AppActivation.bringToFront()
            // 默认按钮是“拒绝”：只有用户刚在 AI 工具里发起连接时才应点允许。
            return alert.runModal(defaultButton: 0, cancelButton: 0) == .alertSecondButtonReturn
        }
    }
}
