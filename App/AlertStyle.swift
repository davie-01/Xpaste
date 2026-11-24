import AppKit

extension NSAlert {
    /// 统一的确认框按钮：不画蓝色焦点框，回车提交的按钮用强调色填充，一眼看出按回车会做什么；Esc 总是取消。
    ///
    /// 系统会把标题叫“取消”的按钮自动设成 Esc，它排在第一个时也就失去了回车，结果哪个按钮都不填色，只剩一圈焦点框（用户截图）。
    /// 这里按序号明确指定：`defaultButton` 响应回车，`cancelButton` 响应 Esc（两个可以是同一个，比如安全起见默认“取消”）。
    func runModal(defaultButton: Int, cancelButton: Int? = nil) -> NSApplication.ModalResponse {
        for (index, button) in buttons.enumerated() {
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
}
