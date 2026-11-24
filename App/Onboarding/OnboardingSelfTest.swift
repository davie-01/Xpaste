#if DEBUG
import AppKit
import PasteCore

@MainActor
enum OnboardingSelfTest {
    static func run(preferences: AppPreferences, check: (String, Bool, String) -> Void) throws {
        defer { preferences.onboardingCompleted = false }
        preferences.onboardingCompleted = false
        check("全新偏好域未完成引导", !preferences.onboardingCompleted, "")

        let model = OnboardingModel(preferences: preferences)
        var finished = 0
        model.onFinish = { finished += 1 }
        model.back()
        check("首页不能再返回", model.page == .intro, "")
        model.next()
        model.next()
        check("介绍 → 快速启动 → 授权", model.page == .permissions && !preferences.onboardingCompleted, "")
        model.back()
        check("可返回上一页", model.page == .quickStart, "")
        model.next()
        model.next()
        check("授权页继续即完成并记住", finished == 1 && preferences.onboardingCompleted, "")

        preferences.onboardingCompleted = false
        let skipped = OnboardingModel(preferences: preferences)
        skipped.onFinish = { finished += 1 }
        skipped.next()
        skipped.finish()
        check("中途跳过也记为完成", finished == 2 && preferences.onboardingCompleted, "")

        preferences.onboardingCompleted = false
        var retained: RetentionPeriod?
        let controller = OnboardingWindowController(preferences: preferences, onRetention: { retained = $0 },
                                                    onKeyboardChange: { _ in }, onRecording: { _ in nil })
        check("引导窗口尺寸", controller.window?.frame.size == OnboardingWindowController.size, "\(controller.window?.frame.size ?? .zero)")
        controller.window?.orderFront(nil)
        controller.window?.close()
        check("直接关闭窗口也记为完成", preferences.onboardingCompleted, "")

        // 加长期限不需确认，清理成功才写偏好；同档不重复清理。
        preferences.retention = .month
        let lengthened = try SettingsActions.changeRetention(to: .year, preferences: preferences, apply: { retained = $0 })
        check("加长保留期限直接生效", lengthened && retained == .year && preferences.retention == .year, "")
        retained = nil
        _ = try SettingsActions.changeRetention(to: .year, preferences: preferences, apply: { retained = $0 })
        check("同档期限不重复清理", retained == nil, "")
        struct Failure: Error {}
        _ = try? SettingsActions.changeRetention(to: .forever, preferences: preferences, apply: { _ in throw Failure() })
        check("清理失败不写入期限", preferences.retention == .year, "")
        preferences.retention = .month

        var invalid = preferences.keyboardSettings
        invalid.activation = RecordedShortcut(keyCode: 37, flags: .option)
        let message = SettingsActions.saveKeyboard(invalid, preferences: preferences, apply: { _ in })
        check("引导里录制非法组合不写入", message != nil && preferences.keyboardSettings.activation != invalid.activation, "")
    }
}
#endif
