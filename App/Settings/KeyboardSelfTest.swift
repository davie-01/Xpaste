#if DEBUG
import AppKit
import ClipboardKit
import PasteCore

@MainActor
enum KeyboardSelfTest {
    static func run(preferences: AppPreferences, check: (String, Bool, String) -> Void) throws {
        defer { preferences.keyboardSettings = .defaults }
        var config = KeyboardSettings.defaults
        config.activation = nil
        config.quickPaste = .control
        config.plainText = .option
        preferences.keyboardSettings = config
        check("快捷键清除与修饰键可重新解码", preferences.keyboardSettings == config && preferences.keyboardSettings.activation == nil, "")
        preferences.keyboardSettings = .defaults
        let settings = KeyboardSettings.defaults
        let optionOnly = RecordedShortcut(keyCode: 37, flags: .option)
        let menuKey = RecordedShortcut(keyCode: 12, flags: .command)
        let systemKey = RecordedShortcut(keyCode: 49, flags: .command)
        check("Option 单独组合被拒绝", ShortcutValidation.error(for: optionOnly, action: .activate, settings: settings, systemShortcuts: []) == String(localized: "只按 Option 不够，请同时按住 Command 或 Control。"), "")
        check("应用菜单组合被拒绝", ShortcutValidation.error(for: menuKey, action: .activate, settings: settings, systemShortcuts: []) == String(localized: "这个组合与应用菜单快捷键冲突。"), "")
        check("系统保留组合被拒绝", ShortcutValidation.error(for: systemKey, action: .activate, settings: settings, systemShortcuts: [systemKey]) == String(localized: "这个组合与已启用的系统快捷键冲突。"), "")
        check("重复的录制组合被拒绝", ShortcutValidation.error(for: settings.stack!, action: .activate, settings: settings, systemShortcuts: []) != nil, "")
        check("快速粘贴组合不被全局热键覆盖", ShortcutValidation.error(for: RecordedShortcut(keyCode: 18, flags: .command), action: .activate, settings: settings, systemShortcuts: []) != nil, "")
        check("合法的 Control Option 功能键可录制", ShortcutValidation.error(for: RecordedShortcut(keyCode: 79, flags: [.control,.option]), action: .activate, settings: settings, systemShortcuts: []) == nil, "")
        var sameModifier = settings
        sameModifier.plainText = .command
        check("快速粘贴与纯文本不能用同一修饰键", ShortcutValidation.error(in: sameModifier, comparedTo: settings, systemShortcuts: []) == String(localized: "快速粘贴和纯文本模式不能使用同一个修饰键。"), "")
        preferences.keyboardSettings = sameModifier
        check("相同修饰键的旧数据回退为默认", preferences.keyboardSettings == .defaults, "")
        preferences.keyboardSettings = .defaults
        var stale = settings
        stale.activation = systemKey
        var modifierOnly = stale
        modifierOnly.quickPaste = .control
        modifierOnly.stack = RecordedShortcut(keyCode: 79, flags: [.control,.option])
        check("已保存组合后来冲突不阻止修改其他项", ShortcutValidation.error(in: modifierOnly, comparedTo: stale, systemShortcuts: [systemKey]) == nil, "")
        var digitBinding = settings
        digitBinding.nextPinboard = RecordedShortcut(keyCode: 18, flags: .control)
        var switchedQuick = digitBinding
        switchedQuick.quickPaste = .control
        check("改修饰键时仍检查已有组合并指明是哪一项", ShortcutValidation.error(in: switchedQuick, comparedTo: digitBinding, systemShortcuts: [])
            == String(localized: "“\(ShortcutAction.nextPinboard.title)”：\(String(localized: "这个组合与快速粘贴或纯文本模式冲突。"))"), "")
        print("INFO 系统启用的快捷键数量：\(ShortcutValidation.enabledSystemShortcuts().count)")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 80), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let recorder = ShortcutRecorderView(frame: NSRect(x: 10, y: 10, width: 121, height: 25))
        window.contentView?.addSubview(recorder)
        recorder.shortcut = settings.activation
        var changed: [RecordedShortcut?] = []
        var recording: [Bool] = []
        recorder.onChange = { changed.append($0); return nil }
        recorder.onRecording = { recording.append($0) }
        recorder.beginRecording()
        check("录制框尺寸与进入录制", recorder.frame.size == NSSize(width: 121, height: 25) && recorder.isRecording, "")
        recorder.keyDown(with: event(53, flags: []))
        check("Esc 取消不修改旧值并结束录制", changed.isEmpty && !recorder.isRecording && recording == [true,false], "")
        recorder.beginRecording()
        _ = recorder.performKeyEquivalent(with: event(40, flags: [.command,.control]))
        check("录制框接收组合并停止录制", changed.count == 1 && changed[0] == RecordedShortcut(keyCode: 40, flags: [.command,.control]) && !recorder.isRecording, "")
        recorder.beginRecording()
        window.makeFirstResponder(nil)
        check("失去焦点自动停止录制", !recorder.isRecording && recording.last == false, "")
        recorder.beginRecording()
        recorder.keyDown(with: event(48, flags: .control))
        check("带修饰键的 Tab 可以录制", changed.last! == RecordedShortcut(keyCode: 48, flags: .control), "")
        recorder.keyDown(with: event(51, flags: []))
        check("Delete 清除录制框中的组合", changed.count == 3 && changed[2] == nil, "")
        recorder.beginRecording()
        window.close()
        check("关闭窗口停止录制并恢复注册回调", !recorder.isRecording && recording.last == false, "")

        // 真实 Carbon 注册：挑未占用的功能键，构造冲突后确认旧绑定被重新注册。
        let flags: NSEvent.ModifierFlags = [.command,.control,.option]
        var initial: RecordedShortcut?
        var probe: HotKey?
        for key in [UInt16(79),80,105,107,113,106,64,90] {
            let value = RecordedShortcut(keyCode: key, flags: flags)
            if let hotKey = HotKey(keyCode: Int(key), modifiers: value.carbonModifiers, action: {}) { initial = value; probe = hotKey; break }
        }
        guard let initial else { check("Carbon 测试有可用组合", false, "没有找到空闲功能键"); return }
        probe = nil
        let registry = GlobalShortcutRegistry(activate: {}, stack: {})
        var bindings = settings
        bindings.activation = initial
        bindings.stack = nil
        try registry.apply(bindings)
        probe = HotKey(keyCode: Int(initial.keyCode), modifiers: initial.carbonModifiers, action: {})
        check("Carbon 真实注册占用组合", probe == nil, "")
        probe = nil
        try registry.setRecording(true)
        probe = HotKey(keyCode: Int(initial.keyCode), modifiers: initial.carbonModifiers, action: {})
        check("录制期间注销全局热键", probe != nil, "")
        probe = nil
        try registry.setRecording(false)
        probe = HotKey(keyCode: Int(initial.keyCode), modifiers: initial.carbonModifiers, action: {})
        check("录制结束重新注册全局热键", probe == nil, "")
        probe = nil
        var blocker: HotKey?
        var blocked: RecordedShortcut?
        for key in [UInt16(79),80,105,107,113,106,64,90] where key != initial.keyCode {
            let value = RecordedShortcut(keyCode: key, flags: flags)
            if let hotKey = HotKey(keyCode: Int(key), modifiers: value.carbonModifiers, action: {}) { blocked = value; blocker = hotKey; break }
        }
        if let blocked {
            var replacement = bindings
            replacement.activation = blocked
            var failed = false
            do { try registry.apply(replacement) } catch { failed = true }
            probe = HotKey(keyCode: Int(initial.keyCode), modifiers: initial.carbonModifiers, action: {})
            check("注册冲突失败后旧组合仍可用", failed && registry.bindings[.activate] == initial && probe == nil, "")
            probe = nil
            let startup = GlobalShortcutRegistry(activate: {}, stack: {})
            var occupied = settings
            occupied.activation = initial
            occupied.stack = blocked
            do { try startup.load(occupied) } catch {}
            occupied.stack = nil
            var cleared = true
            do { try startup.apply(occupied) } catch { cleared = false }
            check("两项启动冲突仍可逐项清除", cleared && startup.bindings[.activate] == initial && startup.bindings[.stack] == nil, "")
            let retrying = GlobalShortcutRegistry(activate: {}, stack: {})
            var pending = settings
            pending.activation = blocked
            pending.stack = nil
            do { try retrying.load(pending) } catch {}
            var stillBlocked = false
            do { try retrying.apply(pending) } catch { stillBlocked = true }
            blocker = nil
            var retried = true
            do { try retrying.apply(pending) } catch { retried = false }
            withExtendedLifetime(retrying) {
                probe = HotKey(keyCode: Int(blocked.keyCode), modifiers: blocked.carbonModifiers, action: {})
                check("占用解除后再次保存同一组合会重新注册", stillBlocked && retried && probe == nil, "")
                probe = nil
            }
        } else { check("Carbon 冲突测试有可用组合", false, "") }
        withExtendedLifetime(blocker) {}
        blocker = nil
        bindings.activation = nil
        try registry.apply(bindings)
        probe = HotKey(keyCode: Int(initial.keyCode), modifiers: initial.carbonModifiers, action: {})
        check("清除快捷键释放 Carbon 注册", probe != nil, "")
        probe = nil
    }

    static func checkPanel(store: HistoryStore, preferences: AppPreferences, check: (String, Bool, String) -> Void) async throws {
        let panel = PanelController(store: store, preferences: preferences)
        panel.animationsEnabled = false
        defer { panel.hide(); preferences.keyboardSettings = .defaults }
        var config = KeyboardSettings.defaults
        config.quickPaste = .control
        config.plainText = .option
        config.nextPinboard = RecordedShortcut(keyCode: 124, flags: [.control,.option])
        config.previousPinboard = RecordedShortcut(keyCode: 123, flags: [.control,.option])
        preferences.keyboardSettings = config
        var pastedPlain: Bool?
        panel.onPaste = { _, plain, _, _ in pastedPlain = plain }
        panel.show()
        await panel.debugSettle()
        panel.debugPress(keyCode: 18, characters: "1", modifiers: .control)
        await panel.debugSettle()
        check("快速粘贴使用设置的 Control", !panel.isVisible && pastedPlain == false, "")
        panel.show()
        await panel.debugSettle()
        panel.debugPress(keyCode: 18, characters: "1", modifiers: [.control,.option])
        await panel.debugSettle()
        check("快速粘贴叠加纯文本修饰键", !panel.isVisible && pastedPlain == true, "")
        panel.show()
        await panel.debugSettle()
        panel.debugPress(keyCode: 36, modifiers: .option)
        await panel.debugSettle()
        check("纯文本 Return 使用设置的 Option", !panel.isVisible && pastedPlain == true, "")
        panel.show()
        await panel.debugSettle()
        panel.debugPress(keyCode: 36, modifiers: .shift)
        await panel.debugSettle()
        check("旧的 Shift Return 不再触发粘贴", panel.isVisible, "")
        panel.hide()
        panel.show()
        await panel.debugSettle()
        let composing = panel.debugBeginComposition("组合输入")
        panel.debugPress(keyCode: 18, characters: "1", modifiers: [.control,.option])
        await panel.debugSettle()
        check("组字期间新的快速粘贴组合被屏蔽", composing && panel.isVisible, "")
        panel.hide()
        let board = try store.createPinboard(name: "快捷键自检", colorHex: "#4B8DF7")
        panel.show()
        await panel.debugSettle()
        panel.debugPress(keyCode: 124, modifiers: [.control,.option])
        await panel.debugSettle()
        check("自定义下一个 Pinboard 生效", panel.debugScope == .pinboard(board.id), "")
        panel.debugPress(keyCode: 123, modifiers: [.control,.option])
        await panel.debugSettle()
        check("自定义上一个 Pinboard 生效", panel.debugScope == .history, "")
        panel.debugFocusSearch("abc")
        await panel.debugSettle()
        _ = panel.debugPerformKeyEquivalent(keyCode: 124, modifiers: [.control,.option])
        await panel.debugSettle()
        check("搜索框有文字时 Pinboard 快捷键留给文本编辑", panel.debugScope == .history, "")
        panel.debugFocusSearch("")
        await panel.debugSettle()
        _ = panel.debugPerformKeyEquivalent(keyCode: 124, modifiers: [.control,.option])
        await panel.debugSettle()
        check("空搜索框里仍可切换 Pinboard", panel.debugScope == .pinboard(board.id), "")
        _ = panel.debugPerformKeyEquivalent(keyCode: 123, modifiers: [.control,.option])
        await panel.debugSettle()
        config.nextPinboard = nil
        preferences.keyboardSettings = config
        panel.debugPress(keyCode: 124, modifiers: [.control,.option])
        await panel.debugSettle()
        check("清除 Pinboard 快捷键立即生效", panel.debugScope == .history, "")
    }
    private static func event(_ keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)!
    }
}
#endif
