import AppKit
import ClipboardKit

/// 内容已写入剪贴板后才询问；授权引导结束后由用户重新发起粘贴。
@MainActor
final class DirectPastePermission {
    static var isTrusted: Bool {
        #if DEBUG
        // 验收未授权界面，不撤销真实授权；只有独立测试域中可用。
        if AppPreferences.testProfile != nil,
           ProcessInfo.processInfo.environment["XPASTE_SIMULATE_UNTRUSTED"] == "1" { return false }
        #endif
        return PastePerformer.isTrusted
    }
    private let preferences: AppPreferences
    private let isTrusted: () -> Bool
    private let requestTrust: () -> Void
    /// 参数是要粘贴进去的应用名称。
    private let ask: (String?) -> (enable: Bool, suppress: Bool)
    private var isPresenting = false

    init(preferences: AppPreferences = .shared,
         isTrusted: @escaping () -> Bool = { DirectPastePermission.isTrusted },
         requestTrust: @escaping () -> Void = { PastePerformer.requestTrust() },
         ask: @escaping (String?) -> (enable: Bool, suppress: Bool) = { DirectPastePermission.presentQuestion(appName: $0) }) {
        self.preferences = preferences
        self.isTrusted = isTrusted
        self.requestTrust = requestTrust
        self.ask = ask
    }

    @discardableResult
    func explainIfNeeded(appName: String? = nil) -> Bool {
        guard !isTrusted(), !preferences.suppressDirectPasteQuestion, !isPresenting else { return false }
        isPresenting = true
        defer { isPresenting = false }
        let answer = ask(appName)
        preferences.suppressDirectPasteQuestion = answer.suppress
        if answer.enable { requestTrust() }
        return answer.enable
    }

    static func presentQuestion(appName: String?) -> (enable: Bool, suppress: Bool) {
        DirectPasteQuestion(appName: appName).run()
    }
}

enum PanelTip: String, CaseIterable {
    case directPaste, openAtLogin
}
