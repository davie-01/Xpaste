import AppKit
import SwiftUI

/// 设置里的“关于”页：应用图标、名称、版本，检查更新和 GitHub 入口。
struct AboutSettingsView: View {
    @State private var checking = false
    @State private var result: UpdateChecker.Result?

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 24)
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 112, height: 112).accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(AppInfo.name).font(.system(size: 24, weight: .bold))
                Text("版本 \(AppInfo.version)（\(AppInfo.build)）").foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Button {
                    Task { await check() }
                } label: {
                    HStack(spacing: 6) {
                        if checking { ProgressView().controlSize(.small) }
                        checking ? Text("正在检查…") : Text("检查更新")
                    }.frame(minWidth: 96)
                }.disabled(checking)
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
            resultView.frame(minHeight: 40, alignment: .top)
            Spacer()
            Text("MIT 许可证 · 免费开源").font(.footnote).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity)
    }

    @ViewBuilder private var resultView: some View {
        switch result {
        case nil:
            EmptyView()
        case .upToDate:
            Label("已是最新版本", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
        case .available(let version, let page):
            VStack(spacing: 6) {
                Label("有新版本 \(version)", systemImage: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                Button("前往下载页") { NSWorkspace.shared.open(page) }.buttonStyle(.link)
            }
        case .notPublished:
            Label("还没有发布过版本", systemImage: "info.circle").foregroundStyle(.secondary)
        case .failed(let message):
            VStack(spacing: 4) {
                Label("检查更新失败", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private func check() async {
        checking = true
        result = nil
        let outcome = await UpdateChecker.check()
        checking = false
        result = outcome
    }
}
