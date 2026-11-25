import AppKit
import ServiceManagement
import PasteCore

/// 设置窗口与引导共用的操作：确认框、登录项、保留期限、快捷键保存。
@MainActor
enum SettingsActions {
    /// 从 SwiftUI 控件（按钮、滑块、选择器）里弹确认框时，先让这次事件处理结束再弹。
    /// 在 SwiftUI 的处理里直接阻塞弹出系统确认框，确认框里标红的按钮画不出来，要鼠标碰一下才出现
    /// （用户真机 2026-11-25：“删除历史…”的“删除”按钮看不到；同一个确认框从后台任务弹出时正常）。
    static func afterCurrentEvent(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    /// 不可撤销操作的确认：回车和 Esc 都是“取消”，操作按钮写具体动作（“删除”“缩短”，不写“继续”）、标红，只能点。
    static func confirm(title: String, detail: String, action: String, preferences: AppPreferences = .shared) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: String(localized: "取消"))
        alert.addButton(withTitle: action)
        alert.buttons[1].hasDestructiveAction = true
        WindowSharing.apply(to: alert.window, preferences: preferences)
        return alert.runModal(defaultButton: 0, cancelButton: 0) == .alertSecondButtonReturn
    }

    /// 以系统服务状态为准，不另存布尔值。
    static var isLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// 注册后仍需用户在系统设置里批准时返回说明。
    static func setLogin(_ enabled: Bool) throws -> String? {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        return enabled && !isLoginEnabled ? String(localized: "请在系统设置的“登录项”中批准 XPaste。") : nil
    }

    /// 缩短期限先确认；取消时返回 false，偏好不变。清理成功后才写入偏好。
    static func changeRetention(to period: RetentionPeriod, preferences: AppPreferences,
                                apply: (RetentionPeriod) throws -> Void) throws -> Bool {
        let old = preferences.retention
        guard period != old else { return true }
        let all = RetentionPeriod.allCases
        if all.firstIndex(of: period)! < all.firstIndex(of: old)!,
           !confirm(title: String(localized: "缩短历史保留期限？"), detail: String(localized: "超过新保留期限的历史将被清理。已固定的项目会保留，清理无法撤销。"),
                    action: String(localized: "缩短"), preferences: preferences) {
            return false
        }
        try apply(period)
        preferences.retention = period
        return true
    }

    /// 校验并注册成功后才写入偏好；返回错误文案。
    static func saveKeyboard(_ candidate: KeyboardSettings, preferences: AppPreferences,
                             apply: (KeyboardSettings) throws -> Void) -> String? {
        if let message = ShortcutValidation.error(in: candidate, comparedTo: preferences.keyboardSettings) { return message }
        do {
            try apply(candidate)
            preferences.keyboardSettings = candidate
            return nil
        } catch { return error.localizedDescription }
    }
}

extension RetentionPeriod {
    var title: String {
        switch self {
        case .day: String(localized: "1 天")
        case .week: String(localized: "1 周")
        case .month: String(localized: "1 个月")
        case .threeMonths: String(localized: "3 个月")
        case .sixMonths: String(localized: "半年")
        case .year: String(localized: "1 年")
        case .forever: String(localized: "永久")
        }
    }
}
