import AppKit
import SwiftUI

/// 设置里的“关于”页：应用图标、名称、版本，检查更新（Sparkle）和 GitHub 入口。
struct AboutSettingsView: View {
    @State private var checksAtLaunch = AppPreferences.shared.checksForUpdatesAtLaunch

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 24)
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 112, height: 112).accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(AppInfo.name).font(.system(size: 24, weight: .bold))
                Text("版本 \(AppInfo.version)（\(AppInfo.build)）").foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                // 结果（已是最新、有新版本、出错）由 Sparkle 自己的窗口显示。
                Button {
                    Updates.shared.checkForUpdates()
                } label: {
                    Text("检查更新…").frame(minWidth: 96)
                }
                if let url = AppInfo.repositoryURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.right.square")
                            Text("在 GitHub 上查看")
                        }
                    }
                }
            }.controlSize(.large).padding(.top, 6)
            Toggle("启动时检查更新", isOn: $checksAtLaunch)
                .onChange(of: checksAtLaunch) { _, value in AppPreferences.shared.checksForUpdatesAtLaunch = value }
            Text("只在启动时检查一次，有新版本才提示；关掉后只在点“检查更新…”时联网。")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
            Text("MIT 许可证 · 免费开源").font(.footnote).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity)
    }
}
