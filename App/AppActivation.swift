import AppKit

/// 把 XPaste 带到前台，用于打开设置、弹说明框等。
///
/// 面板不激活应用，别的应用一直在前台；macOS 的协作式激活下 `NSApp.activate()` 这时不生效，
/// 设置窗口、说明框会出在那个应用后面（L103、L109）。从当前前台应用那里接过激活才行（M5 第 9 步实测）。
@MainActor
enum AppActivation {
    static func bringToFront() {
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            NSRunningApplication.current.activate(from: front, options: [])
        } else {
            NSApp.activate()
        }
    }
}

/// 打开系统设置“隐私与安全性”里的某一页，例如 `Privacy_Accessibility`（macOS 27 叫“设备控制和数据访问”）。
enum SystemSettings {
    static func openPrivacy(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
