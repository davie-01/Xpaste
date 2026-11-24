import AppKit

@MainActor
enum WindowSharing {
    /// 旧式共享标记；现代录屏 API 可能忽略，不能视为屏幕捕获保护。
    static func apply(to window: NSWindow, preferences: AppPreferences = .shared) {
        window.sharingType = preferences.showDuringScreenSharing ? .readOnly : .none
    }
}
