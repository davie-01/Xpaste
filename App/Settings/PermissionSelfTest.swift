#if DEBUG
import Foundation

@MainActor
enum PermissionSelfTest {
    static func run(preferences: AppPreferences, check: (String, Bool, String) -> Void) {
        var trusted = false
        var prompts = 0
        var requests = 0
        var enable = false
        var suppress = false
        let permission = DirectPastePermission(preferences: preferences, isTrusted: { trusted },
            requestTrust: { requests += 1 }, ask: { _ in prompts += 1; return (enable, suppress) })
        let deferred = permission.explainIfNeeded()
        check("未授权可暂不启用且不请求系统权限", !deferred && prompts == 1 && requests == 0, "")
        enable = true
        let requested = permission.explainIfNeeded()
        check("明确启用时才请求辅助功能权限", requested && prompts == 2 && requests == 1, "")
        trusted = true
        permission.explainIfNeeded()
        check("已有授权不再询问", prompts == 2 && requests == 1, "")
        trusted = false
        enable = false
        suppress = true
        permission.explainIfNeeded()
        let reloaded = AppPreferences(defaults: preferences.defaults)
        let restarted = DirectPastePermission(preferences: reloaded, isTrusted: { false },
            requestTrust: { requests += 1 }, ask: { _ in prompts += 1; return (true, false) })
        restarted.explainIfNeeded()
        check("不要再问了跨控制器持久化且保持复制降级", prompts == 3 && requests == 1 && reloaded.suppressDirectPasteQuestion, "")

        preferences.pasteToApplication = true
        check("未授权且登录项未启用时显示两张提示", preferences.visibleTips(isTrusted: false, loginEnabled: false) == [.directPaste, .openAtLogin], "")
        check("授权与登录状态自动隐藏对应提示", preferences.visibleTips(isTrusted: true, loginEnabled: true).isEmpty, "")
        preferences.pasteToApplication = false
        check("仅复制模式不推荐直接粘贴", preferences.visibleTips(isTrusted: false, loginEnabled: false) == [.openAtLogin], "")
        preferences.pasteToApplication = true
        // 提示上的 × 只关本次面板显示，不写偏好；旧版本留下的关闭记录也不再挡住提示。
        preferences.defaults.set(true, forKey: "dismissedTip.directPaste")
        check("旧版关闭记录不挡住仍未授权时的权限提示", reloaded.visibleTips(isTrusted: false, loginEnabled: true) == [.directPaste], "")
        preferences.defaults.removeObject(forKey: "dismissedTip.directPaste")
        preferences.suppressDirectPasteQuestion = false
        preferences.pasteToApplication = false
    }
}
#endif
