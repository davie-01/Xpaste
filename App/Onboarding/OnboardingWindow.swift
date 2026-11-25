import AppKit
import SwiftUI
import ClipboardKit
import PasteCore

/// 首次启动的引导：介绍 → 快速启动 → 授权。走完、在任一页跳过或关闭窗口都记为完成，之后不再出现。
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let size = NSSize(width: 560, height: 480)
    let model: OnboardingModel

    init(preferences: AppPreferences = .shared, onRetention: @escaping (RetentionPeriod) throws -> Void,
         onKeyboardChange: @escaping (KeyboardSettings) throws -> Void, onRecording: @escaping (Bool) -> String?) {
        let window = StandardWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                                    styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        WindowSharing.apply(to: window, preferences: preferences)
        window.title = String(localized: "欢迎使用 XPaste")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        model = OnboardingModel(preferences: preferences)
        super.init(window: window)
        window.delegate = self
        model.onFinish = { [weak self] in self?.close() }
        let hostingView = makeHostingView(OnboardingView(model: model, preferences: preferences, onRetention: onRetention,
                                                                 onKeyboardChange: onKeyboardChange, onRecording: onRecording))
        hostingView.sizingOptions = []
        window.contentView = hostingView
        window.setFrame(NSRect(origin: .zero, size: Self.size), display: false)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        AppActivation.bringToFront()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { model.markCompleted() }
}

@MainActor @Observable
final class OnboardingModel {
    enum Page: Int, CaseIterable { case intro, quickStart, permissions }
    private(set) var page = Page.intro
    @ObservationIgnored var onFinish: () -> Void = {}
    @ObservationIgnored private let preferences: AppPreferences

    init(preferences: AppPreferences) { self.preferences = preferences }

    func next() {
        if let next = Page(rawValue: page.rawValue + 1) { page = next } else { finish() }
    }
    func back() {
        if let previous = Page(rawValue: page.rawValue - 1) { page = previous }
    }
    func finish() {
        markCompleted()
        onFinish()
    }
    func markCompleted() { preferences.onboardingCompleted = true }
}

private struct OnboardingView: View {
    let model: OnboardingModel
    let preferences: AppPreferences
    let onRetention: (RetentionPeriod) throws -> Void
    let onKeyboardChange: (KeyboardSettings) throws -> Void
    let onRecording: (Bool) -> String?
    @State private var trusted = DirectPastePermission.isTrusted

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.page {
                case .intro: IntroPage()
                case .quickStart: QuickStartPage(preferences: preferences, onRetention: onRetention,
                                                 onKeyboardChange: onKeyboardChange, onRecording: onRecording)
                case .permissions: PermissionsPage(trusted: $trusted)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            HStack {
                if model.page != .permissions {
                    Button("跳过引导") { model.finish() }.buttonStyle(OnboardingButtonStyle(kind: .link))
                }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(OnboardingModel.Page.allCases, id: \.self) { page in
                        Circle().fill(page == model.page ? Color.accentColor : Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
                    }
                }.accessibilityHidden(true)
                Spacer()
                if model.page != .intro { Button("返回") { model.back() }.buttonStyle(OnboardingButtonStyle()) }
                Button(primaryTitle) { model.next() }.buttonStyle(OnboardingButtonStyle(kind: .prominent)).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 24).padding(.vertical, 18)
        }
        .padding(.top, 28)
        .frame(width: OnboardingWindowController.size.width, height: OnboardingWindowController.size.height)
        .ignoresSafeArea()
    }

    private var primaryTitle: String {
        switch model.page {
        case .intro, .quickStart: String(localized: "继续")
        case .permissions: trusted ? String(localized: "完成") : String(localized: "以后再做")
        }
    }
}

private struct PageHeader: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            // 自制示意：系统符号加渐变底，不使用原版资源。
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.white)
                .frame(width: 72, height: 72).background(.blue.gradient, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityHidden(true)
            Text(title).font(.system(size: 22, weight: .bold))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 420)
        }
    }
}

private struct IntroPage: View {

    var body: some View {
        VStack(spacing: 24) {
            PageHeader(symbol: "clipboard", title: String(localized: "欢迎使用 XPaste"),
                       detail: String(localized: "XPaste 会记住你复制过的内容。用激活快捷键或菜单栏图标打开剪贴板历史，选中即可粘贴；激活快捷键在下一步设置。"))
            VStack(alignment: .leading, spacing: 14) {
                feature("clock.arrow.circlepath", String(localized: "剪贴板历史"), String(localized: "文字、图片、链接和文件都会保留，可以搜索和预览。"))
                feature("pin", String(localized: "Pinboard"), String(localized: "把常用内容固定到分组里，不受保留期限影响。"))
                feature("square.stack", String(localized: "Paste Stack"), String(localized: "一次收集多项，再按顺序逐项粘贴。"))
            }.frame(maxWidth: 400, alignment: .leading)
        }.padding(.horizontal, 40)
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Color.accentColor).frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct QuickStartPage: View {
    let preferences: AppPreferences
    let onRetention: (RetentionPeriod) throws -> Void
    let onKeyboardChange: (KeyboardSettings) throws -> Void
    let onRecording: (Bool) -> String?
    @State private var shortcut: RecordedShortcut?
    @State private var retention: RetentionPeriod
    @State private var login = SettingsActions.isLoginEnabled
    @State private var message: String?

    init(preferences: AppPreferences, onRetention: @escaping (RetentionPeriod) throws -> Void,
         onKeyboardChange: @escaping (KeyboardSettings) throws -> Void, onRecording: @escaping (Bool) -> String?) {
        self.preferences = preferences
        self.onRetention = onRetention
        self.onKeyboardChange = onKeyboardChange
        self.onRecording = onRecording
        _shortcut = State(initialValue: preferences.keyboardSettings.activation)
        _retention = State(initialValue: preferences.retention)
    }

    var body: some View {
        VStack(spacing: 24) {
            PageHeader(symbol: "bolt", title: String(localized: "快速启动"),
                       detail: String(localized: "这些设置以后都可以在“设置”里修改。"))
            VStack(spacing: 0) {
                row(String(localized: "激活快捷键")) {
                    ShortcutRecorder(title: String(localized: "激活快捷键"), shortcut: shortcut, onChange: { value in
                        var candidate = preferences.keyboardSettings
                        candidate.activation = value
                        let error = SettingsActions.saveKeyboard(candidate, preferences: preferences, apply: onKeyboardChange)
                        if error == nil { shortcut = value; message = nil }
                        return error
                    }, onRecording: { message = onRecording($0) }, onError: { message = $0 }).frame(width: 121, height: 25)
                }
                Divider()
                row(String(localized: "保留历史")) {
                    Picker(String(localized: "保留历史"), selection: Binding(get: { retention }, set: setRetention)) {
                        ForEach(RetentionPeriod.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                Divider()
                row(String(localized: "登录时打开")) {
                    Toggle(String(localized: "登录时打开"), isOn: Binding(get: { login }, set: setLogin))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }.padding(.horizontal, 12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: 420)
            if let message {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 420)
            }
        }.padding(.horizontal, 40)
    }

    private func row(_ title: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(title)
            Spacer()
            control()
        }.frame(height: 40)
    }

    private func setRetention(_ period: RetentionPeriod) {
        // 缩短期限会弹确认框，等这次选择处理结束后再弹（见 `SettingsActions.afterCurrentEvent`）。
        SettingsActions.afterCurrentEvent {
            do {
                if try SettingsActions.changeRetention(to: period, preferences: preferences, apply: onRetention) { retention = period; message = nil }
            } catch { message = error.localizedDescription }
        }
    }

    private func setLogin(_ enabled: Bool) {
        do { message = try SettingsActions.setLogin(enabled) } catch { message = error.localizedDescription }
        login = SettingsActions.isLoginEnabled
    }
}

private struct PermissionsPage: View {
    @Binding var trusted: Bool
    @State private var fullDiskAccess = FullDiskAccess.isGranted

    var body: some View {
        VStack(spacing: 20) {
            PageHeader(symbol: "hand.raised", title: String(localized: "允许直接粘贴"),
                       detail: String(localized: "在系统设置的“设备控制和数据访问”中允许 XPaste 后，选中的内容会直接粘贴到正在使用的应用。不允许也能使用：内容会复制到剪贴板，由你按 ⌘V 粘贴。"))
            if trusted {
                Label(String(localized: "已允许直接粘贴"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                HStack(spacing: 10) {
                    Button(String(localized: "允许访问")) { PastePerformer.requestTrust() }.buttonStyle(OnboardingButtonStyle())
                    Button(String(localized: "打开系统设置")) { Self.openSettings("Privacy_Accessibility") }.buttonStyle(OnboardingButtonStyle())
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("可选：完全磁盘访问").fontWeight(.semibold)
                Text("粘贴“文稿”“桌面”“下载”等文件夹里的文件时，系统会逐个文件夹询问。授予完全磁盘访问后不再询问。XPaste 只读取你复制过的文件，不会扫描磁盘。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                // 已授予时和上面的“已允许直接粘贴”一样显示绿色说明，不再给按钮（用户真机，2026-11-25）。
                if fullDiskAccess {
                    Label(String(localized: "已允许完全磁盘访问"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button(String(localized: "打开完全磁盘访问设置")) { Self.openSettings("Privacy_AllFiles") }.buttonStyle(OnboardingButtonStyle())
                }
            }.padding(12).frame(maxWidth: 420, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        }.padding(.horizontal, 40)
            // 系统不通知授权变化，停留在这一页时每秒读一次。
            .task {
                while !Task.isCancelled {
                    trusted = DirectPastePermission.isTrusted
                    fullDiskAccess = FullDiskAccess.isGranted
                    try? await Task.sleep(for: .seconds(1))
                }
            }
    }

    static func openSettings(_ pane: String) { SystemSettings.openPrivacy(pane) }
}

/// 引导页的按钮：不画焦点环，鼠标移入、移出和按下时底色有变化。
private struct OnboardingButtonStyle: ButtonStyle {
    enum Kind { case standard, prominent, link }
    var kind = Kind.standard

    func makeBody(configuration: Configuration) -> some View {
        HoverButton(configuration: configuration, kind: kind)
    }

    private struct HoverButton: View {
        let configuration: Configuration
        let kind: Kind
        @State private var hovering = false

        var body: some View {
            Group {
                if kind == .link {
                    configuration.label
                        .foregroundStyle(Color.accentColor.opacity(configuration.isPressed ? 0.6 : hovering ? 0.8 : 1))
                        .underline(hovering)
                } else {
                    configuration.label
                        .padding(.horizontal, 14).frame(minWidth: 64, minHeight: 28)
                        .foregroundStyle(kind == .prominent ? Color.white : Color.primary)
                        .background(background, in: RoundedRectangle(cornerRadius: 7))
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
        }

        private var background: Color {
            if kind == .prominent {
                // 移入略亮，按下略暗。
                return Color.accentColor.mix(with: configuration.isPressed ? .black : .white,
                                             by: configuration.isPressed ? 0.18 : hovering ? 0.14 : 0)
            }
            return Color.primary.opacity(configuration.isPressed ? 0.26 : hovering ? 0.2 : 0.08)
        }
    }
}
