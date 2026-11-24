import AppKit
import Carbon.HIToolbox

struct RecordedShortcut: Codable, Equatable, Hashable, Sendable {
    let keyCode: UInt16
    let modifiers: UInt

    init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        modifiers = flags.intersection([.command, .shift, .control, .option]).rawValue
    }
    var flags: NSEvent.ModifierFlags { .init(rawValue: modifiers) }
    var carbonModifiers: Int {
        (flags.contains(.command) ? cmdKey : 0) | (flags.contains(.shift) ? shiftKey : 0)
        | (flags.contains(.control) ? controlKey : 0) | (flags.contains(.option) ? optionKey : 0)
    }
    func matches(_ event: NSEvent) -> Bool {
        keyCode == event.keyCode && flags == event.modifierFlags.intersection([.command, .shift, .control, .option])
    }
    @MainActor var display: String { Self.symbols(flags) + Self.keyName(keyCode) }
    static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
        + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
    }
    static let functionKeys: [UInt16: String] = [122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12",105:"F13",107:"F14",113:"F15",106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"]
    @MainActor static func keyName(_ keyCode: UInt16) -> String {
        if let name = functionKeys[keyCode] { return name }
        if let name = [UInt16(36):"↩",48:"⇥",49:"Space",51:"⌫",53:"⎋",76:"⌤",115:"↖",119:"↘",116:"⇞",121:"⇟",117:"⌦",123:"←",124:"→",125:"↓",126:"↑"][keyCode] { return name }
        let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "\(keyCode)" }
        let data = unsafeBitCast(pointer, to: CFData.self)
        let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
        var dead: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        guard status == noErr, length > 0 else { return "\(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case activate, stack, nextPinboard, previousPinboard
    var id: Self { self }
    var title: String {
        switch self {
        case .activate: String(localized: "启动 XPaste")
        case .stack: String(localized: "启动 Stack")
        case .nextPinboard: String(localized: "显示下一个 Pinboard")
        case .previousPinboard: String(localized: "显示上一个 Pinboard")
        }
    }
}

enum ShortcutModifier: String, Codable, CaseIterable, Sendable {
    case command, shift, control, option
    var flags: NSEvent.ModifierFlags {
        switch self { case .command: .command; case .shift: .shift; case .control: .control; case .option: .option }
    }
    var title: String {
        switch self { case .command: "⌘ Command"; case .shift: "⇧ Shift"; case .control: "⌃ Control"; case .option: "⌥ Option" }
    }
}

struct KeyboardSettings: Codable, Equatable, Sendable {
    var activation: RecordedShortcut?
    var stack: RecordedShortcut?
    var nextPinboard: RecordedShortcut?
    var previousPinboard: RecordedShortcut?
    var quickPaste: ShortcutModifier = .command
    var plainText: ShortcutModifier = .shift

    static var defaults: Self {
        #if DEBUG
        let flags: NSEvent.ModifierFlags = [.control, .shift, .command]
        #else
        let flags: NSEvent.ModifierFlags = [.shift, .command]
        #endif
        return Self(activation: .init(keyCode: 9, flags: flags), stack: .init(keyCode: 8, flags: flags),
                    nextPinboard: .init(keyCode: 124, flags: .command), previousPinboard: .init(keyCode: 123, flags: .command))
    }
    subscript(_ action: ShortcutAction) -> RecordedShortcut? {
        get {
            switch action { case .activate: activation; case .stack: stack; case .nextPinboard: nextPinboard; case .previousPinboard: previousPinboard }
        }
        set {
            switch action { case .activate: activation = newValue; case .stack: stack = newValue; case .nextPinboard: nextPinboard = newValue; case .previousPinboard: previousPinboard = newValue }
        }
    }
}

@MainActor
enum ShortcutValidation {
    static func error(for shortcut: RecordedShortcut, action: ShortcutAction, settings: KeyboardSettings,
                      systemShortcuts: Set<RecordedShortcut>? = nil) -> String? {
        guard shortcut.keyCode < 128 else { return String(localized: "这个按键无法用作快捷键。") }
        let flags = shortcut.flags
        if flags.contains(.option), flags.isDisjoint(with: [.command, .control]) {
            return String(localized: "只按 Option 不够，请同时按住 Command 或 Control。")
        }
        if flags.isDisjoint(with: [.command, .control]), RecordedShortcut.functionKeys[shortcut.keyCode] == nil {
            return String(localized: "请组合 Command 或 Control，或使用功能键。")
        }
        if ShortcutAction.allCases.contains(where: { $0 != action && settings[$0] == shortcut }) {
            return String(localized: "这个组合已用于另一项 XPaste 快捷键。")
        }
        if let message = modifierConflict(shortcut, settings: settings) { return message }
        let menuKeys: Set<UInt16> = [0, 6, 7, 8, 9, 12, 13, 14, 15, 31, 3, 43, 45]
        if flags == .command && menuKeys.contains(shortcut.keyCode)
            || flags == [.command, .shift] && [6,45].contains(shortcut.keyCode)
            || menuConflict(shortcut, menu: NSApp.mainMenu) {
            return String(localized: "这个组合与应用菜单快捷键冲突。")
        }
        if (systemShortcuts ?? enabledSystemShortcuts()).contains(shortcut) {
            return String(localized: "这个组合与已启用的系统快捷键冲突。")
        }
        return nil
    }
    /// 只校验改动的部分：之前保存的组合后来与系统快捷键冲突时，不应阻止修改其他项。
    static func error(in candidate: KeyboardSettings, comparedTo current: KeyboardSettings,
                      systemShortcuts: Set<RecordedShortcut>? = nil) -> String? {
        // 两者相同时无法区分快速粘贴是否要纯文本。
        if candidate.quickPaste == candidate.plainText {
            return String(localized: "快速粘贴和纯文本模式不能使用同一个修饰键。")
        }
        let modifiersChanged = candidate.quickPaste != current.quickPaste || candidate.plainText != current.plainText
        let systemShortcuts = systemShortcuts ?? enabledSystemShortcuts()
        for action in ShortcutAction.allCases {
            guard let value = candidate[action] else { continue }
            let message = value != current[action]
                ? error(for: value, action: action, settings: candidate, systemShortcuts: systemShortcuts)
                : modifiersChanged ? modifierConflict(value, settings: candidate) : nil
            if let message { return String(localized: "“\(action.title)”：\(message)") }
        }
        return nil
    }
    static func modifierConflict(_ shortcut: RecordedShortcut, settings: KeyboardSettings) -> String? {
        let flags = shortcut.flags
        let digitKeys: Set<UInt16> = [18,19,20,21,23,22,26,28,25]
        if digitKeys.contains(shortcut.keyCode) && (flags == settings.quickPaste.flags || flags == settings.quickPaste.flags.union(settings.plainText.flags))
            || [36,76].contains(shortcut.keyCode) && flags == settings.plainText.flags {
            return String(localized: "这个组合与快速粘贴或纯文本模式冲突。")
        }
        return nil
    }
    static func enabledSystemShortcuts() -> Set<RecordedShortcut> {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr, let values = array?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return Set(values.compactMap { value in
            guard value["kHISymbolicHotKeyEnabled"] as? Bool == true,
                  let code = value["kHISymbolicHotKeyCode"] as? Int, (0..<128).contains(code),
                  let modifiers = value["kHISymbolicHotKeyModifiers"] as? Int else { return nil }
            var flags: NSEvent.ModifierFlags = []
            if modifiers & cmdKey != 0 { flags.insert(.command) }
            if modifiers & shiftKey != 0 { flags.insert(.shift) }
            if modifiers & optionKey != 0 { flags.insert(.option) }
            if modifiers & controlKey != 0 { flags.insert(.control) }
            return RecordedShortcut(keyCode: UInt16(code), flags: flags)
        })
    }
    private static func menuConflict(_ shortcut: RecordedShortcut, menu: NSMenu?) -> Bool {
        guard let menu else { return false }
        for item in menu.items {
            if !item.keyEquivalent.isEmpty, item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift]) == shortcut.flags,
               item.keyEquivalent.uppercased() == RecordedShortcut.keyName(shortcut.keyCode) { return true }
            if menuConflict(shortcut, menu: item.submenu) { return true }
        }
        return false
    }
}
