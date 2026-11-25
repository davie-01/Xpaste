import AppKit
import SwiftUI

/// 第一次直接粘贴却还没有授权时的说明框。版式照原版：上面一张示意图，下面是标题、说明、两个整行按钮和“不要再问了”；
/// 示意图、标题和说明都是自己的。内容在弹出前已经放进剪贴板。
@MainActor
final class DirectPasteQuestion {
    private let appName: String?
    private var answer = (enable: false, suppress: false)

    init(appName: String?) { self.appName = appName }

    /// 模态显示，返回用户的选择。Esc 等于“暂不启用”。
    func run() -> (enable: Bool, suppress: Bool) {
        let panel = QuestionPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 380), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.title = String(localized: "启用直接粘贴？")

        let glass = NSGlassEffectView()
        glass.cornerRadius = 28
        var suppress = false
        let content = QuestionView(appName: appName, suppress: Binding(get: { suppress }, set: { suppress = $0 })) { [weak panel] enable in
            self.answer = (enable, suppress)
            NSApp.stopModal()
            panel?.orderOut(nil)
        }
        let hosting = makeHostingView(content)
        hosting.sizingOptions = [.intrinsicContentSize]
        glass.contentView = hosting
        panel.contentView = glass
        panel.setContentSize(hosting.fittingSize)
        panel.onCancel = { [weak panel] in
            self.answer = (false, suppress)
            NSApp.stopModal()
            panel?.orderOut(nil)
        }
        WindowSharing.apply(to: panel)
        AppActivation.bringToFront()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        return answer
    }
}

/// 无边框窗口默认不能成为 key，按钮和复选框就收不到键盘；Esc 关闭。
private final class QuestionPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private struct QuestionView: View {
    let appName: String?
    @Binding var suppress: Bool
    let onAnswer: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Illustration().frame(width: 200, height: 110).padding(.bottom, 18).accessibilityHidden(true)
            Text(appName.map { String(localized: "要直接粘贴到“\($0)”吗？") } ?? String(localized: "启用直接粘贴？"))
                .font(.system(size: 17, weight: .bold)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
            Text("XPaste 需要在系统设置的“设备控制和数据访问”中获得允许，才能把内容直接粘贴到其他应用。这次的内容已放进剪贴板。")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 20)
            Button { onAnswer(true) } label: {
                Text("允许直接粘贴").frame(maxWidth: .infinity, minHeight: 34)
            }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.defaultAction)
                .padding(.bottom, 8)
            Button { onAnswer(false) } label: {
                Text("暂不启用，复制到剪贴板").frame(maxWidth: .infinity, minHeight: 34)
            }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
                .padding(.bottom, 14)
            Toggle("不要再问了", isOn: $suppress).toggleStyle(.checkbox)
        }.padding(.horizontal, 24).padding(.top, 26).padding(.bottom, 20).frame(width: 300)
    }
}

/// 自制示意图：一张卡片沿着弧形箭头落进应用窗口里的光标位置。
private struct Illustration: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.85))
                .frame(width: 130, height: 92).offset(x: 30, y: 4)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 4) { ForEach(0..<3) { _ in Circle().fill(Color.gray.opacity(0.5)).frame(width: 6, height: 6) } }
                ForEach([96, 80, 60], id: \.self) { width in
                    Capsule().fill(Color.gray.opacity(0.35)).frame(width: CGFloat(width), height: 4)
                }
                HStack(spacing: 2) {
                    Capsule().fill(Color.gray.opacity(0.35)).frame(width: 34, height: 4)
                    Rectangle().fill(Color.accentColor).frame(width: 2, height: 12)
                }
            }.frame(width: 130, height: 92, alignment: .topLeading).padding(.leading, 24).offset(x: 30, y: 10)
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor)
                .overlay(Image(systemName: "doc.on.clipboard").font(.system(size: 20, weight: .medium)).foregroundStyle(.white))
                .frame(width: 46, height: 46).offset(x: -70, y: 30)
            Image(systemName: "arrow.turn.right.up").font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.accentColor)
                .offset(x: -48, y: -14)
        }
    }
}
