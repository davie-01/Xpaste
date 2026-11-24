import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PrivacySettingsView: View {
    let preferences: AppPreferences
    let onChange: () -> Void
    @State private var showDuringSharing: Bool
    @State private var linkPreviews: Bool
    @State private var confidential: Bool
    @State private var transient: Bool
    @State private var ignoredIDs: Set<String>
    @State private var selection: String?
    @State private var error: String?

    init(preferences: AppPreferences, onChange: @escaping () -> Void) {
        self.preferences = preferences
        self.onChange = onChange
        _showDuringSharing = State(initialValue: preferences.showDuringScreenSharing)
        _linkPreviews = State(initialValue: preferences.generateLinkPreviews)
        _confidential = State(initialValue: preferences.ignoreConfidential)
        _transient = State(initialValue: preferences.ignoreTransient)
        _ignoredIDs = State(initialValue: preferences.ignoredBundleIDs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 0) {
                privacyRow(String(localized: "在屏幕共享期间显示"), detail: String(localized: "关闭时设置窗口隐藏标记；部分录屏和共享方式可能仍可见。"), value: Binding(get: { showDuringSharing }, set: {
                    showDuringSharing = $0
                    preferences.showDuringScreenSharing = $0
                    onChange()
                }))
                Divider()
                privacyRow(String(localized: "生成链接预览"), detail: String(localized: "允许访问公开链接获取标题和配图，可能消耗一次性链接。"), value: Binding(get: { linkPreviews }, set: {
                    linkPreviews = $0
                    preferences.generateLinkPreviews = $0
                    onChange()
                }))
            }.privacyGroup()
            VStack(spacing: 0) {
                privacyRow(String(localized: "忽略机密内容"), detail: String(localized: "跳过带机密标记的复制内容；不能识别所有敏感信息。"), value: Binding(get: { confidential }, set: {
                    confidential = $0
                    preferences.ignoreConfidential = $0
                    onChange()
                }))
                Divider()
                privacyRow(String(localized: "忽略瞬时内容"), detail: String(localized: "跳过其他应用标记为临时或自动生成的内容。"), value: Binding(get: { transient }, set: {
                    transient = $0
                    preferences.ignoreTransient = $0
                    onChange()
                }))
            }.privacyGroup()
            VStack(alignment: .leading, spacing: 4) {
                Text("忽略应用程序").fontWeight(.semibold)
                Text("不记录这些应用今后复制的内容；已有历史会保留。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 10)
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(applications) { app in
                        HStack(spacing: 10) {
                            Image(nsImage: app.icon).resizable().scaledToFit().frame(width: 26, height: 26)
                            Text(app.name).lineLimit(1).truncationMode(.middle)
                        }.padding(.vertical, 3).tag(app.id)
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden).frame(height: 140)
                Divider()
                // `.plain` 样式只有图标的笔画能点到，整块都要能点（L115）。
                HStack(spacing: 0) {
                    Button(action: chooseApplications) { Image(systemName: "plus").frame(width: 28, height: 24).contentShape(Rectangle()) }
                        .help(String(localized: "添加忽略应用")).accessibilityLabel(String(localized: "添加忽略应用"))
                    Divider().frame(height: 16)
                    Button(action: removeSelection) { Image(systemName: "minus").frame(width: 28, height: 24).contentShape(Rectangle()) }
                        .disabled(selection == nil)
                        .help(String(localized: "移除忽略应用")).accessibilityLabel(String(localized: "移除忽略应用"))
                    Spacer()
                }.buttonStyle(.plain).padding(.horizontal, 4).padding(.vertical, 3)
            }.background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12)).clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .alert(String(localized: "无法添加应用"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var applications: [IgnoredApplication] {
        ignoredIDs.map(IgnoredApplication.init).sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private func privacyRow(_ title: String, detail: String, value: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .scaleEffect(0.84, anchor: .trailing).frame(width: 36, height: 16).padding(.top, 1)
        }.padding(.vertical, 10)
    }

    private func chooseApplications() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "选择应用")
        WindowSharing.apply(to: panel, preferences: preferences)
        panel.begin { response in
            guard response == .OK else { return }
            var invalid: [String] = []
            for url in panel.urls {
                guard let identifier = Bundle(url: url)?.bundleIdentifier, !identifier.isEmpty else {
                    invalid.append(url.lastPathComponent)
                    continue
                }
                ignoredIDs.insert(identifier)
            }
            preferences.ignoredBundleIDs = ignoredIDs
            onChange()
            if !invalid.isEmpty { error = String(localized: "这些应用没有可识别的应用标识：\(invalid.joined(separator: "、"))") }
        }
    }

    private func removeSelection() {
        guard let selection else { return }
        ignoredIDs.remove(selection)
        self.selection = nil
        preferences.ignoredBundleIDs = ignoredIDs
        onChange()
    }
}

private struct IgnoredApplication: Identifiable {
    let id: String
    let name: String
    let icon: NSImage

    init(_ bundleID: String) {
        id = bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            name = bundleID
            icon = NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        }
    }
}

private extension View {
    func privacyGroup() -> some View {
        padding(.horizontal, 10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}
