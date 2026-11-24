import AppKit
import SwiftUI
import ClipboardKit
import PasteCore

@MainActor
final class SettingsWindowController: NSWindowController {
    init(preferences: AppPreferences = .shared, savesFrame: Bool = true, onRetention: @escaping (RetentionPeriod) throws -> Void,
         onEraseHistory: @escaping () throws -> Void, onPrivacyChange: @escaping () -> Void = {},
         onKeyboardChange: @escaping (KeyboardSettings) throws -> Void = { _ in },
         onRecording: @escaping (Bool) -> String? = { _ in nil }, mcp: MCPSettingsModel? = nil,
         onRecognizeAgain: @escaping () throws -> Int = { 0 }) {
        let window = StandardWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 592),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        WindowSharing.apply(to: window, preferences: preferences)
        window.title = String(localized: "设置")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let hostingView = NSHostingView(rootView: SettingsView(navigation: navigation, preferences: preferences, onRetention: onRetention, onEraseHistory: onEraseHistory, onPrivacyChange: onPrivacyChange, onKeyboardChange: onKeyboardChange, onRecording: onRecording, mcp: mcp, onRecognizeAgain: onRecognizeAgain))
        // 固定的是整窗尺寸；避免 SwiftUI 将固定内容高度再加上系统标题栏作为最小窗口高度。
        hostingView.sizingOptions = []
        window.contentView = hostingView
        window.setFrame(NSRect(x: 0, y: 0, width: 640, height: 592), display: false)
        window.center()
        if savesFrame { window.setFrameAutosaveName("XPasteSettings") }
        // 窗口关掉就停止看授权状态（窗口对象留着复用，SwiftUI 的定时订阅不会自己停）。
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { TrustStatus.shared.stopWatching() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 控制器关窗后会被放掉（`OnDemandWindow`），通知要跟着移除。
    nonisolated(unsafe) private var closeObserver: NSObjectProtocol?
    deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }

    private let navigation = SettingsNavigation()

    /// 打开设置；给了页面就切到那一页（“关于 XPaste”打开关于页）。
    func present(page: SettingsPage? = nil) {
        if let page { navigation.page = page }
        TrustStatus.shared.startWatching()
        AppActivation.bringToFront()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// “直接粘贴”授权的当前状态，设置窗口里各处共用一份（审查：设置权限）。
/// 只在设置窗口开着时每秒看一次（用户可能正在系统设置里切换），窗口关掉就停。
@MainActor @Observable
final class TrustStatus {
    static let shared = TrustStatus()
    private(set) var isTrusted = DirectPastePermission.isTrusted
    @ObservationIgnored private var timer: Timer?

    func startWatching() {
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let value = DirectPastePermission.isTrusted
        if value != isTrusted { isTrusted = value }
    }
}

/// 设置、引导这类普通窗口。应用菜单里没有“窗口”菜单，⌘W 在这里处理。
final class StandardWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// 当前显示的设置页，窗口外面（菜单）也能切换。
@MainActor @Observable
final class SettingsNavigation {
    var page = SettingsPage.general
}

enum SettingsPage: Int, CaseIterable, Identifiable {
    case general, privacy, keyboard, mcp, about
    var id: Self { self }
    var title: String {
        switch self {
        case .general: String(localized: "通用")
        case .privacy: String(localized: "隐私")
        case .keyboard: String(localized: "键盘快捷键")
        case .mcp: String(localized: "MCP 与 AI 工具")
        case .about: String(localized: "关于")
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .privacy: "hand.raised"
        case .keyboard: "keyboard"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .about: "info.circle"
        }
    }
}

private struct SettingsView: View {
    @Bindable var navigation: SettingsNavigation
    let preferences: AppPreferences
    let onRetention: (RetentionPeriod) throws -> Void
    let onEraseHistory: () throws -> Void
    let onPrivacyChange: () -> Void
    let onKeyboardChange: (KeyboardSettings) throws -> Void
    let onRecording: (Bool) -> String?
    let mcp: MCPSettingsModel?
    let onRecognizeAgain: () throws -> Int
    private var page: SettingsPage {
        get { navigation.page }
        nonmutating set { navigation.page = newValue }
    }
    /// 还没允许直接粘贴时“通用”一行后面挂一个红色感叹号（原版如此）。窗口开着时每秒看一次，授权后马上消失。
    private var trusted: Bool { TrustStatus.shared.isTrusted }
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ForEach(SettingsPage.allCases) { item in
                    Button { page = item } label: {
                        // 照原版截图排：图标中心距窗口左边约 29 pt，文字从 46 pt 开始，各行对齐。
                        HStack(spacing: 6) {
                            // 原版窗口在前台时侧栏图标用强调色，退到后台变灰；选中的那一行整行白字加粗（L89）。图标比正文大，约 19 pt。
                            Image(systemName: item.symbol)
                                .font(.system(size: 17))
                                .frame(width: 22)
                                .foregroundStyle(page == item ? Color.white : appearsActive ? Color.accentColor : Color.secondary)
                                .accessibilityHidden(true)
                            Text(item.title).fontWeight(page == item ? .semibold : .regular)
                            if item == .general, !trusted {
                                Spacer(minLength: 0)
                                Image(systemName: "exclamationmark.circle.fill").symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .red).font(.system(size: 16))
                                    .accessibilityLabel(String(localized: "直接粘贴未启用"))
                            }
                        }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 8).padding(.trailing, 10).frame(height: 32)
                            .background(page == item ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(page == item ? Color.white : Color.primary)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).focusEffectDisabled()
                        // 选中的页只靠底色区分，VoiceOver 要另外告诉它。
                        .accessibilityAddTraits(page == item ? .isSelected : [])
                }
                Spacer()
            }.padding(.horizontal, 10).padding(.top, 50).frame(width: 200)
                .background(.regularMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(page.title).font(.system(size: 17, weight: .bold)).padding(.leading, 10).padding(.bottom, 18)
                if page == .general {
                    ScrollView {
                        GeneralSettingsView(preferences: preferences, onRetention: onRetention, onEraseHistory: onEraseHistory,
                                            onRecognizeAgain: onRecognizeAgain).padding(.bottom, 2)
                    }.scrollBounceBehavior(.basedOnSize)
                } else if page == .privacy {
                    ScrollView {
                        PrivacySettingsView(preferences: preferences, onChange: onPrivacyChange)
                            .padding(.bottom, 2)
                    }.scrollBounceBehavior(.basedOnSize)
                } else if page == .keyboard {
                    KeyboardSettingsView(preferences: preferences, onChange: onKeyboardChange, onRecording: onRecording)
                } else if page == .mcp, let mcp {
                    ScrollView {
                        MCPSettingsView(model: mcp).padding(.bottom, 2)
                    }.scrollBounceBehavior(.basedOnSize)
                } else if page == .about {
                    AboutSettingsView()
                } else {
                    Text("此页将在后续步骤中完成。").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(width: 640, height: 592).ignoresSafeArea()
    }
}

private struct GeneralSettingsView: View {
    let preferences: AppPreferences
    let onRetention: (RetentionPeriod) throws -> Void
    let onEraseHistory: () throws -> Void
    let onRecognizeAgain: () throws -> Int
    @State private var sound: Bool
    @State private var direct: Bool
    @State private var plain: Bool
    @State private var retention: Double
    @State private var editingRetention = false
    @State private var login = false
    private var trusted: Bool { TrustStatus.shared.isTrusted }
    @State private var error: String?

    init(preferences: AppPreferences, onRetention: @escaping (RetentionPeriod) throws -> Void,
         onEraseHistory: @escaping () throws -> Void, onRecognizeAgain: @escaping () throws -> Int) {
        self.preferences = preferences
        self.onRetention = onRetention
        self.onEraseHistory = onEraseHistory
        self.onRecognizeAgain = onRecognizeAgain
        _sound = State(initialValue: preferences.soundEffectsEnabled)
        _direct = State(initialValue: preferences.pasteToApplication)
        _plain = State(initialValue: preferences.alwaysPastePlainText)
        _retention = State(initialValue: Double(RetentionPeriod.allCases.firstIndex(of: preferences.retention) ?? 2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 0) {
                switchRow(String(localized: "登录时打开"), isOn: Binding(get: { login }, set: setLogin))
                Divider()
                switchRow(String(localized: "音效"), isOn: $sound)
                    .onChange(of: sound) { _, value in preferences.soundEffectsEnabled = value }
            }.padding(.horizontal, 10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            Text("粘贴项目").fontWeight(.semibold).padding(.leading, 10)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        pasteOption(true, title: String(localized: "到当前活动应用"), detail: String(localized: "选好条目后，立即粘贴到你正在用的应用里。"))
                        if !trusted, direct {
                            // 还没允许直接粘贴：选项下面给一个去开启的入口（原版如此）。
                            Button { PastePerformer.requestTrust() } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .red)
                                    Text("允许直接粘贴")
                                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                }.padding(.horizontal, 10).frame(height: 28)
                                    .background(.quaternary.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).padding(.leading, 22)
                        }
                        pasteOption(false, title: String(localized: "到剪贴板"), detail: String(localized: "选好条目后只放进剪贴板，由你自己粘贴。"))
                    }
                    // 自制示意图，不使用原版资源。
                    PasteModeIllustration(direct: direct).frame(width: 150, height: 100).accessibilityHidden(true)
                }
                Divider()
                Toggle("始终以纯文本粘贴", isOn: $plain)
                    .toggleStyle(.checkbox).onChange(of: plain) { _, value in preferences.alwaysPastePlainText = value }
            }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            Text("保留历史").fontWeight(.semibold).padding(.leading, 10)
            VStack(spacing: 10) {
                Slider(value: $retention, in: 0...4, step: 1) {
                    Text("保留历史")
                } onEditingChanged: { editing in
                    editingRetention = editing
                    if !editing { setRetention(retention) }
                }
                .labelsHidden()
                // 滑块的值是档位序号，读出来要换成对应的时长。
                .accessibilityValue(Text(retentionLabel))
                .onChange(of: retention) { _, value in
                    if !editingRetention { setRetention(value) }
                }
                Text(retentionLabel).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Spacer()
                    Button("删除历史…", role: .destructive) {
                        guard SettingsActions.confirm(title: String(localized: "删除所有历史记录？"), detail: String(localized: "未固定的历史项目将永久删除。已固定的项目和 Pinboard 会保留，此操作无法撤销。"), preferences: preferences) else { return }
                        do { try onEraseHistory() } catch { self.error = error.localizedDescription }
                    }
                }
            }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            RecognitionSettingsView(preferences: preferences, onRecognizeAgain: onRecognizeAgain)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
        .alert(String(localized: "无法更改设置"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .scaleEffect(0.84, anchor: .trailing).frame(width: 36, height: 16)
        }.frame(height: 36)
    }

    private func refresh() {
        login = SettingsActions.isLoginEnabled
        sound = preferences.soundEffectsEnabled
        direct = preferences.pasteToApplication
        plain = preferences.alwaysPastePlainText
        retention = Double(RetentionPeriod.allCases.firstIndex(of: preferences.retention) ?? 2)
    }

    private func pasteOption(_ value: Bool, title: String, detail: String) -> some View {
        Button {
            direct = value
            preferences.pasteToApplication = value
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: direct == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(direct == value ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title)
            .accessibilityValue(direct == value ? String(localized: "已选择") : String(localized: "未选择"))
    }

    private var retentionLabel: String { RetentionPeriod.allCases[Int(retention)].title }

    private func setRetention(_ value: Double) {
        let oldIndex = Double(RetentionPeriod.allCases.firstIndex(of: preferences.retention)!)
        do {
            let changed = try SettingsActions.changeRetention(to: RetentionPeriod.allCases[Int(value)], preferences: preferences, apply: onRetention)
            retention = changed ? value : oldIndex
        } catch {
            retention = oldIndex
            self.error = error.localizedDescription
        }
    }

    private func setLogin(_ enabled: Bool) {
        do {
            let notice = try SettingsActions.setLogin(enabled)
            login = SettingsActions.isLoginEnabled
            if let notice { error = notice }
        } catch { self.error = error.localizedDescription }
    }
}

/// 图片文字识别的语言（遗留 L08，原版没有这项设置）。识别结果只用于搜索。
private struct RecognitionSettingsView: View {
    let preferences: AppPreferences
    let onRecognizeAgain: () throws -> Int
    @State private var selected: [String]
    @State private var autoDetect: Bool
    @State private var notice: String?
    private let supported = TextRecognition.supportedLanguages

    init(preferences: AppPreferences, onRecognizeAgain: @escaping () throws -> Int) {
        self.preferences = preferences
        self.onRecognizeAgain = onRecognizeAgain
        _selected = State(initialValue: preferences.recognitionLanguages)
        _autoDetect = State(initialValue: preferences.recognitionAutoDetect)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("图片文字识别").fontWeight(.semibold).padding(.leading, 10)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("识别语言")
                        Text("识别图片中的文字，用于搜索。更改只影响之后识别的图片。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Menu(summary) {
                        ForEach(supported, id: \.id) { language in
                            Toggle(language.name, isOn: Binding(get: { selected.contains(language.id) }, set: { on in toggle(language.id, on) }))
                        }
                        Divider()
                        Toggle("自动检测语言", isOn: Binding(get: { autoDetect }, set: { value in
                            autoDetect = value
                            preferences.recognitionAutoDetect = value
                        }))
                    }.fixedSize()
                }
                Divider()
                HStack {
                    if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("重新识别已有图片") {
                        do {
                            let count = try onRecognizeAgain()
                            notice = String(localized: "已排队 \(count) 张图片，将在后台重新识别。")
                        } catch { notice = error.localizedDescription }
                    }
                }
            }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var summary: String {
        let names = supported.filter { selected.contains($0.id) }.map(\.name)
        guard names.count > 3 else { return names.joined(separator: String(localized: "、")) }
        return String(localized: "\(names.prefix(2).joined(separator: String(localized: "、"))) 等 \(names.count) 种")
    }

    /// 至少保留一种语言。
    private func toggle(_ id: String, _ on: Bool) {
        if on { if !selected.contains(id) { selected.append(id) } }
        else if selected.count > 1 { selected.removeAll { $0 == id } }
        preferences.recognitionLanguages = selected
    }
}

/// “粘贴项目”的示意图：下面一排是面板里的卡片，选中的那张沿箭头飞出去。
/// 到当前活动应用：落进上面应用窗口的光标处，那一行亮起来；到剪贴板：落进剪贴板（打勾），应用窗口不变。
struct PasteModeIllustration: View {
    let direct: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.30, blue: 0.86), Color(red: 0.78, green: 0.36, blue: 0.80)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            // 应用窗口
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().fill(.white.opacity(0.45)).frame(width: 4, height: 4) } }
                Capsule().fill(.white.opacity(0.35)).frame(width: 48, height: 3)
                Capsule().fill(.white.opacity(0.35)).frame(width: 38, height: 3)
                HStack(spacing: 2) {
                    Capsule().fill(direct ? Color.white : .white.opacity(0.35)).frame(width: direct ? 30 : 22, height: 3)
                    Rectangle().fill(.white).frame(width: 1.2, height: 8)
                }
            }.padding(8).frame(width: 74, height: 52, alignment: .topLeading)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .opacity(direct ? 1 : 0.55)
                .offset(x: direct ? 64 : 14, y: 10)
            if !direct {
                // 剪贴板
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "clipboard").font(.system(size: 26, weight: .regular)).foregroundStyle(.white)
                    Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .green)
                        .font(.system(size: 13, weight: .semibold)).offset(x: 5, y: 3)
                }.offset(x: 106, y: 16)
            }
            // 面板里的一排卡片，第二张是选中的
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(.white.opacity(index == 1 ? 0.95 : 0.35))
                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(index == 1 ? Color.accentColor : .clear, lineWidth: 1.5))
                        .frame(width: 18, height: 18)
                }
            }.padding(5).background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .offset(x: 18, y: 70)
            // 飞出去的箭头：从选中的卡片到光标处或剪贴板
            ArrowPath(from: CGPoint(x: 46, y: 70), to: direct ? CGPoint(x: 66, y: 49) : CGPoint(x: 104, y: 38))
                .stroke(.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}

/// 一段向上弯的弧线，末端带箭头。
private struct ArrowPath: Shape {
    let from: CGPoint
    let to: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let control = CGPoint(x: from.x, y: to.y)
        path.move(to: from)
        path.addQuadCurve(to: to, control: control)
        // 箭头方向取曲线末端的切线（从控制点指向终点）。
        let angle = atan2(to.y - control.y, to.x - control.x)
        for side in [-1.0, 1.0] {
            let wing = angle + .pi + side * .pi / 5
            path.move(to: to)
            path.addLine(to: CGPoint(x: to.x + 5 * cos(wing), y: to.y + 5 * sin(wing)))
        }
        return path
    }
}

