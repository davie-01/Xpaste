import AppKit

extension NSAlert {
    /// 统一的确认框按钮：不画蓝色焦点框，回车提交的按钮用强调色填充，一眼看出按回车会做什么；Esc 总是取消。
    ///
    /// 系统会把标题叫“取消”的按钮自动设成 Esc，它排在第一个时也就失去了回车，结果哪个按钮都不填色，只剩一圈焦点框（用户截图）。
    /// 这里按序号明确指定：`defaultButton` 响应回车，`cancelButton` 响应 Esc（两个可以是同一个，比如安全起见默认“取消”）。
    ///
    /// 统一规则（2026-11-25 用户确认，方案 B，见 Docs/设计/弹窗统一方案）：
    /// - 能撤销或风险低的，回车给操作；不能撤销或涉及安全的，回车给“取消 / 拒绝”，危险按钮标 `hasDestructiveAction`（红字）。
    /// - 系统总把响应回车的按钮放在最右边，按钮位置由它决定，与添加顺序无关（实测）。
    /// - 标了 `hasDestructiveAction` 的按钮不响应回车、也不填色（实测；“删除所选”回车没反应就是它），所以回车按钮在这里一律去掉这个标记。
    /// - 按钮的底色、文字色设置都被系统忽略（实测），颜色只能是系统的：回车按钮蓝色实心，其余灰色，危险按钮红字。
    func runModal(defaultButton: Int, cancelButton: Int? = nil) -> NSApplication.ModalResponse {
        for (index, button) in buttons.enumerated() {
            if index == defaultButton { button.hasDestructiveAction = false }
            button.focusRingType = .none
            button.keyEquivalent = index == defaultButton ? "\r" : (index == cancelButton ? "\u{1b}" : "")
            button.keyEquivalentModifierMask = []
        }
        // 默认按钮就是取消按钮时，它占着回车，Esc 另外接住。
        var monitor: Any?
        if let cancelButton, cancelButton == defaultButton, buttons.indices.contains(cancelButton) {
            let cancel = buttons[cancelButton]
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53 else { return event }
                cancel.performClick(nil)
                return nil
            }
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        layout()
        window.initialFirstResponder = nil
        return runModal()
    }

    /// 只有一个“好”的提示框：回车和 Esc 都是“好”。
    static func showMessage(_ title: String, detail: String? = nil, style: NSAlert.Style = .informational, preferences: AppPreferences = .shared) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        if let detail { alert.informativeText = detail }
        alert.addButton(withTitle: String(localized: "好"))
        WindowSharing.apply(to: alert.window, preferences: preferences)
        _ = alert.runModal(defaultButton: 0, cancelButton: 0)
    }
}
