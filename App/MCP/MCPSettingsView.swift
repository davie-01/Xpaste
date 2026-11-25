import AppKit
import SwiftUI
import MCPKit

/// 设置页“MCP 与 AI 工具”的状态。连接列表随客户端文件变化刷新。
@MainActor @Observable
final class MCPSettingsModel {
    private(set) var enabled: Bool
    private(set) var clients: [MCPClient] = []
    private(set) var port: UInt16
    private(set) var error: String?
    /// 连接列表没能写进文件时的说明，弹框告诉用户。
    var storageError: String?
    @ObservationIgnored let controller: MCPController
    @ObservationIgnored private let preferences: AppPreferences

    init(controller: MCPController, preferences: AppPreferences = .shared) {
        self.controller = controller
        self.preferences = preferences
        enabled = preferences.mcpEnabled
        port = preferences.mcpPort
        controller.onClientsChange = { [weak self] in self?.refresh() }
        refresh()
    }

    /// 由可观察的端口算出，改端口后界面跟着刷新。
    var endpointURL: String { "http://127.0.0.1:\(port)/mcp" }

    func refresh() {
        enabled = preferences.mcpEnabled
        port = preferences.mcpPort
        clients = controller.clients.connectedClients
        error = enabled ? controller.lastError : nil
    }

    func setEnabled(_ value: Bool) async {
        preferences.mcpEnabled = value
        enabled = value
        await controller.apply()
        refresh()
    }

    func disconnect(_ client: MCPClient) async {
        storageError = await controller.disconnect(clientID: client.id)
        refresh()
    }

    /// 手动连接：返回令牌明文，只显示这一次。创建失败（写不进文件）时返回 nil，原因放进 `storageError`。
    func createManualClient(name: String) -> String? {
        defer { refresh() }
        do {
            return try controller.clients.createManualClient(name: name).token
        } catch {
            storageError = String(localized: "没能添加“\(name)”：\(error.localizedDescription)")
            return nil
        }
    }

    func changePort(_ value: UInt16) async -> String? {
        let failure = await controller.setPort(value)
        refresh()
        return failure
    }
}

/// 三种连接引导。深链和桌面扩展包不做（Docs/归档/09 第 9 节）。
enum MCPGuide: Identifiable {
    case claudeCode(url: String)
    case config(url: String)
    case token(name: String, url: String, token: String, bridge: String)

    var id: String {
        switch self {
        case .claudeCode: "claude"
        case .config: "config"
        case .token(let name, _, _, _): "token-\(name)"
        }
    }
}

struct MCPSettingsView: View {
    let model: MCPSettingsModel
    @State private var guide: MCPGuide?
    @State private var addingTool = false
    @State private var showingAdvanced = false

    var body: some View {
        // 版式按原版开启态（Docs/归档/调研/08 第 9.24 节）：地址行在开关分组里，连接菜单在列表下方靠右。
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("启用 MCP")
                        Text("允许 AI 应用连接到 XPaste。只有你在 XPaste 中批准的应用才能访问你的剪贴板条目和 Pinboard；服务只在本机监听，其他设备无法连接。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("启用 MCP", isOn: Binding(get: { model.enabled }, set: { value in Task { await model.setEnabled(value) } }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .scaleEffect(0.84, anchor: .trailing).frame(width: 36, height: 16).padding(.top, 1)
                }.padding(.vertical, 10)
                if model.enabled {
                    Divider()
                    HStack(spacing: 6) {
                        Circle().fill(model.error == nil ? Color.green : Color.red).frame(width: 7, height: 7)
                            .accessibilityLabel(model.error == nil ? String(localized: "运行中") : String(localized: "未运行"))
                        Text(model.endpointURL).textSelection(.enabled)
                        CopyButton(text: model.endpointURL)
                        Spacer()
                        Button("高级…") { showingAdvanced = true }
                    }.padding(.vertical, 8)
                    if let error = model.error {
                        Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
                    }
                }
            }.padding(.horizontal, 10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

            if model.enabled {
                Text("已连接的 AI 工具").fontWeight(.semibold).padding(.horizontal, 10)
                VStack(spacing: 0) {
                    if model.clients.isEmpty {
                        Text("尚未连接任何工具").foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 56)
                    } else {
                        ForEach(model.clients) { client in
                            ClientRow(client: client) { disconnect(client) }
                            if client.id != model.clients.last?.id { Divider() }
                        }
                    }
                }.padding(.horizontal, 10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                HStack {
                    Spacer()
                    Menu("连接 AI 工具…") {
                        Button("Claude Code") { guide = .claudeCode(url: model.endpointURL) }
                        Button("其他应用（配置文件）") { guide = .config(url: model.endpointURL) }
                        Divider()
                        Button("自定义工具…") { addingTool = true }
                    }.fixedSize()
                }
            }
        }
        // 最近使用时间是相对时间，打开页面时重新取一次。
        .onAppear { model.refresh() }
        .sheet(item: $guide) { guide in MCPGuideView(guide: guide) { self.guide = nil } }
        .sheet(isPresented: $addingTool) {
            AddToolView { name in
                addingTool = false
                guard let name else { return }
                guard let token = model.createManualClient(name: name) else { return }
                // 等上一个面板收起后再弹出令牌面板。
                DispatchQueue.main.async {
                    guide = .token(name: name, url: model.endpointURL, token: token, bridge: model.controller.bridgePath)
                }
            }
        }
        .sheet(isPresented: $showingAdvanced) { AdvancedView(model: model) { showingAdvanced = false } }
        .onChange(of: model.storageError) { _, message in
            guard let message else { return }
            DispatchQueue.main.async {
                NSAlert.showMessage(String(localized: "连接设置没有保存"), detail: message)
                model.storageError = nil
            }
        }
    }

    private func disconnect(_ client: MCPClient) {
        let alert = NSAlert()
        alert.messageText = String(localized: "要断开“\(client.name)”的连接吗？")
        alert.informativeText = String(localized: "断开后，\(client.name) 要重新连接才能使用 XPaste。")
        alert.addButton(withTitle: String(localized: "取消"))
        alert.addButton(withTitle: String(localized: "断开连接"))
        alert.buttons.last?.hasDestructiveAction = true
        WindowSharing.apply(to: alert.window)
        guard alert.runModal(defaultButton: 0, cancelButton: 0) == .alertSecondButtonReturn else { return }
        Task { await model.disconnect(client) }
    }
}

private struct ClientRow: View {
    let client: MCPClient
    let onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: client.kind == .manual ? "key" : "sparkles").foregroundStyle(.secondary).frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(client.name).lineLimit(1).truncationMode(.middle)
                Text(lastUsed).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("断开连接…", action: onDisconnect)
        }.padding(.vertical, 8)
    }

    private var lastUsed: String {
        guard let date = client.lastUsedAt else { return String(localized: "从未使用") }
        // 相对时间在差值为 0 时会写成“0 秒钟后”。
        guard Date().timeIntervalSince(date) >= 60 else { return String(localized: "刚刚使用") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return String(localized: "最近使用 \(formatter.localizedString(for: date, relativeTo: Date()))")
    }
}

private struct MCPGuideView: View {
    let guide: MCPGuide
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 15, weight: .semibold))
            switch guide {
            case .claudeCode(let url):
                Text("复制下面的命令，在“终端”里运行：")
                CodeBlock(text: "claude mcp add --transport http --scope user xpaste \(url)")
                Text("然后启动 Claude Code，输入 /mcp，选择 xpaste 并完成认证。浏览器打开后，回到 XPaste，在确认框中允许连接。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .config(let url):
                Text("将以下内容添加到你的应用的 MCP 配置中。应用连接时，在 XPaste 的确认框中允许。")
                    .fixedSize(horizontal: false, vertical: true)
                CodeBlock(text: "{\n  \"mcpServers\": {\n    \"xpaste\": {\n      \"url\": \"\(url)\"\n    }\n  }\n}")
            case .token(_, let url, let token, let bridge):
                Text("将以下内容添加到你的 AI 工具的 MCP 配置中。令牌只显示这一次，关闭后无法再查看；不再使用时在列表中断开即可。")
                    .fixedSize(horizontal: false, vertical: true)
                LabeledBlock(label: String(localized: "服务器 URL"), text: url)
                LabeledBlock(label: String(localized: "令牌"), text: token, secret: true)
                LabeledBlock(label: String(localized: "只支持 stdio 的工具"), text: """
                    {
                      "command": "\(bridge)",
                      "env": {
                        "MCP_URL": "\(url)",
                        "MCP_TOKEN": "\(token)"
                      }
                    }
                    """, secret: true)
            }
            HStack {
                Spacer()
                Button("完成", action: onDone).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 520)
    }

    private var title: String {
        switch guide {
        case .claudeCode: String(localized: "连接 Claude Code")
        case .config: String(localized: "连接其他应用")
        case .token(let name, _, _, _): String(localized: "连接 \(name)")
        }
    }
}

private struct LabeledBlock: View {
    let label: String
    let text: String
    var secret = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            CodeBlock(text: text, secret: secret)
        }
    }
}

/// 可选中、可复制的等宽文字块，右侧是复制图标。
private struct CodeBlock: View {
    let text: String
    var secret = false

    var body: some View {
        HStack(alignment: .top) {
            Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(text: text, secret: secret)
        }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 复制图标按钮。含令牌的内容按机密内容写入剪贴板，剪贴板历史（包括 XPaste 自己）不会记录。
private struct CopyButton: View {
    let text: String
    var secret = false
    @State private var copied = false

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            if secret { pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) }
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }.buttonStyle(.borderless)
            .help(copied ? String(localized: "已复制") : String(localized: "复制"))
            .accessibilityLabel(copied ? String(localized: "已复制") : String(localized: "复制"))
    }
}

private struct AddToolView: View {
    let onFinish: (String?) -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加 AI 工具").font(.system(size: 15, weight: .semibold))
            TextField(String(localized: "工具名称"), text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { onFinish(nil) }.keyboardShortcut(.cancelAction)
                Button("创建") { onFinish(trimmed) }.keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty)
            }
        }.padding(20).frame(width: 380)
    }

    private var trimmed: String { String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)) }
}

private struct AdvancedView: View {
    let model: MCPSettingsModel
    let onDone: () -> Void
    @State private var text = ""
    @State private var failure: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MCP 服务器端口").font(.system(size: 15, weight: .semibold))
            TextField("39725", text: $text).textFieldStyle(.roundedBorder).onSubmit(change)
            Text("改用新端口后，已连接的 AI 工具都需要重新连接。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let failure {
                Text("无法更改端口：\(failure)").font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消", action: onDone).keyboardShortcut(.cancelAction)
                Button("更改", action: change).keyboardShortcut(.defaultAction)
                    .disabled(working || newPort == nil || newPort == model.port)
            }
        }.padding(20).frame(width: 380)
            .onAppear { text = String(model.port) }
    }

    private var newPort: UInt16? {
        UInt16(text.trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 1024 ? $0 : nil }
    }

    private func change() {
        guard let port = newPort else { return }
        if !model.clients.isEmpty {
            let alert = NSAlert()
            alert.messageText = String(localized: "更改端口？")
            alert.informativeText = String(localized: "所有已连接的 AI 工具都将断开并移除，需要重新连接。")
            alert.addButton(withTitle: String(localized: "取消"))
            alert.addButton(withTitle: String(localized: "更改"))
            WindowSharing.apply(to: alert.window)
            guard alert.runModal(defaultButton: 0, cancelButton: 0) == .alertSecondButtonReturn else { return }
        }
        working = true
        Task {
            if let error = await model.changePort(port) {
                failure = error
            } else {
                failure = nil
                onDone()
            }
            working = false
        }
    }
}
