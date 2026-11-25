import Foundation
import PasteCore
import ClipboardKit

/// 保留已有键名，升级时沿用用户设置。UserDefaults 自身支持并发访问。
struct AppPreferences: @unchecked Sendable {
    static let shared: AppPreferences = {
        #if BENCH
        return AppPreferences(defaults: UserDefaults(suiteName: benchSuite)!)
        #endif
        #if DEBUG
        if let testProfile { return AppPreferences(defaults: UserDefaults(suiteName: "com.mars.XPaste.settings-test.\(testProfile)")!) }
        #endif
        return AppPreferences(defaults: .standard)
    }()

    #if DEBUG
    /// 可复现的验收：隔离历史、偏好和回放剪贴板，关闭采集；默认打开设置。
    static let testProfile: String? = {
        guard let value = ProcessInfo.processInfo.environment["XPASTE_SETTINGS_TEST"],
              !value.isEmpty, value.count <= 64,
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) else { return nil }
        return value
    }()
    #endif
    #if BENCH
    /// 测量构建只用这个偏好域，开始和结束时都清空。
    static let benchSuite = "com.mars.XPaste.bench"
    #endif
    let defaults: UserDefaults

    /// 走完、跳过或关闭引导后为 true，之后不再出现。
    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: "onboardingCompleted") }
        nonmutating set { defaults.set(newValue, forKey: "onboardingCompleted") }
    }
    var suppressDirectPasteQuestion: Bool {
        get { defaults.bool(forKey: "suppressDirectPasteQuestion") }
        nonmutating set { defaults.set(newValue, forKey: "suppressDirectPasteQuestion") }
    }
    /// 面板上该显示哪些提示。只看当前条件，不记关闭：提示上的 × 只关这一次面板显示（由面板自己记），
    /// 以前版本留下的 `dismissedTip.*` 键不再读取。
    func visibleTips(isTrusted: Bool, loginEnabled: Bool) -> [PanelTip] {
        PanelTip.allCases.filter { tip in
            tip == .directPaste ? pasteToApplication && !isTrusted : !loginEnabled
        }
    }

    var keyboardSettings: KeyboardSettings {
        get {
            guard let data = defaults.data(forKey: "keyboardSettings"),
                  let value = try? JSONDecoder().decode(KeyboardSettings.self, from: data), value.quickPaste != .shift, value.quickPaste != value.plainText else { return .defaults }
            return value
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: "keyboardSettings") }
        }
    }
    /// 启动时静默检查一次更新（见 `Updates`）。默认开；关掉后只在用户点“检查更新…”时联网。
    var checksForUpdatesAtLaunch: Bool {
        get { defaults.object(forKey: "checksForUpdatesAtLaunch") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "checksForUpdatesAtLaunch") }
    }
    var soundEffectsEnabled: Bool {
        get { defaults.object(forKey: "soundEffectsEnabled") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "soundEffectsEnabled") }
    }
    var generateLinkPreviews: Bool {
        get { defaults.object(forKey: "generateLinkPreviews") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "generateLinkPreviews") }
    }
    var showDuringScreenSharing: Bool {
        get { defaults.object(forKey: "showDuringScreenSharing") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "showDuringScreenSharing") }
    }
    var ignoreConfidential: Bool {
        get { defaults.object(forKey: "ignoreConfidential") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "ignoreConfidential") }
    }
    var ignoreTransient: Bool {
        get { defaults.object(forKey: "ignoreTransient") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "ignoreTransient") }
    }
    var capturePolicy: CapturePolicy {
        var policy = CapturePolicy()
        policy.ignoreConfidential = ignoreConfidential
        policy.ignoreTransient = ignoreTransient
        policy.ignoredBundleIDs = ignoredBundleIDs
        return policy
    }
    var pasteToApplication: Bool {
        get { defaults.object(forKey: "pasteToApplication") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "pasteToApplication") }
    }
    var alwaysPastePlainText: Bool {
        get { defaults.bool(forKey: "alwaysPastePlainText") }
        nonmutating set { defaults.set(newValue, forKey: "alwaysPastePlainText") }
    }
    var retention: RetentionPeriod {
        get { defaults.string(forKey: "historyRetention").flatMap(RetentionPeriod.init(rawValue:)) ?? .month }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "historyRetention") }
    }
    var ignoredBundleIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: "ignoredBundleIdentifiers") ?? ["com.apple.Passwords", "com.apple.keychainaccess"]) }
        nonmutating set { defaults.set(newValue.sorted(), forKey: "ignoredBundleIdentifiers") }
    }
    var panelHeight: Double {
        get { defaults.double(forKey: "panelHeight") }
        nonmutating set { defaults.set(newValue, forKey: "panelHeight") }
    }
    /// 面板高度锁定：上缘拖不动、双击不还原，直到解锁。
    var panelHeightLocked: Bool {
        get { defaults.bool(forKey: "panelHeightLocked") }
        nonmutating set { defaults.set(newValue, forKey: "panelHeightLocked") }
    }
    var stackReversed: Bool {
        get { defaults.bool(forKey: "stackReversed") }
        nonmutating set { defaults.set(newValue, forKey: "stackReversed") }
    }
    /// Stack 的“以纯文本粘贴”：打开后 ⌘V、双击、全部粘贴都只粘文本（Docs/归档/验收记录/Stack改版.md S10）。
    var stackPastePlainText: Bool {
        get { defaults.bool(forKey: "stackPastePlainText") }
        nonmutating set { defaults.set(newValue, forKey: "stackPastePlainText") }
    }
    /// 图片文字识别的语言（`Locale.Language.maximalIdentifier`）。默认简体、繁体中文和英文，与之前写死的一致。
    var recognitionLanguages: [String] {
        get {
            let stored = defaults.stringArray(forKey: "recognitionLanguages") ?? []
            return stored.isEmpty ? ["zh-Hans", "zh-Hant", "en-US"].map { Locale.Language(identifier: $0).maximalIdentifier } : stored
        }
        nonmutating set { defaults.set(newValue, forKey: "recognitionLanguages") }
    }
    /// 让系统自动判断图片里的语言（会增加识别耗时）。
    var recognitionAutoDetect: Bool {
        get { defaults.bool(forKey: "recognitionAutoDetect") }
        nonmutating set { defaults.set(newValue, forKey: "recognitionAutoDetect") }
    }

    /// MCP 服务默认关闭；关闭时不监听任何端口。
    var mcpEnabled: Bool {
        get { defaults.bool(forKey: "mcpEnabled") }
        nonmutating set { defaults.set(newValue, forKey: "mcpEnabled") }
    }
    var mcpPort: UInt16 {
        get { UInt16(exactly: defaults.integer(forKey: "mcpPort")).flatMap { $0 >= 1024 ? $0 : nil } ?? 39725 }
        nonmutating set { defaults.set(Int(newValue), forKey: "mcpPort") }
    }
    var stackWindowTopLeft: String? {
        get { defaults.string(forKey: "stackWindowTopLeft") }
        nonmutating set { defaults.set(newValue, forKey: "stackWindowTopLeft") }
    }
}
