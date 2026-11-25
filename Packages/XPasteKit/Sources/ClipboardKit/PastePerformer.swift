import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

/// 向前台应用发送一次 ⌘V。需要辅助功能授权；未授权时调用方应降级为只写剪贴板。
@MainActor
public enum PastePerformer {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 本应用自己发出的 ⌘V 带这个标记，Stack 的事件拦截据此放行，不把它当成用户按的。
    public static let ownEventTag: Int64 = 0x5850_5354

    /// 弹出系统的辅助功能授权引导。
    public static func requestTrust() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// 先调用 `stillValid` 复核目标、剪贴板和请求（审查 01），成立就立刻发 ⌘V，不成立不发。返回是否发出了。
    /// 不等触发热键的修饰键松开：用户按住 ⇧ 回车、⌘ 加数字、⌃⌥⌘V 时手指可能还没离开，照样立刻粘贴（用户要求，2026-11-25）。
    /// 以前等松开、超过 0.5 秒就放弃，⇧回车 慢一点松手就只剩“已复制”。见 `postPaste` 为什么不会变成 ⇧⌘V。
    public static func postPaste(stillValid: () -> Bool) -> Bool {
        guard isTrusted, stillValid() else { return false }
        return postPaste()
    }

    /// 发一次 ⌘V。用私有事件源生成、修饰键字段明确只有 ⌘：用户此刻按着的 ⇧、⌥、⌃ 不会叠加进去，
    /// 应用按事件里的修饰键匹配菜单快捷键，收到的就是 ⌘V（实测：模拟按住 ⇧ 时发出，前台应用触发的是 ⌘V 菜单项，
    /// 事件和应用查到的当前修饰键里都没有 ⇧）。
    @discardableResult
    public static func postPaste() -> Bool {
        guard isTrusted, let source = CGEventSource(stateID: .privateState) else { return false }
        let keyV = keyCodeForCommandV()
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: ownEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: ownEventTag)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    /// 当前键盘布局下，按住 ⌘ 时产生 “v” 的那个键。
    /// 按住 ⌘ 来查，是为了同时覆盖 Dvorak（V 换了位置）和 “Dvorak – QWERTY ⌘”（按 ⌘ 时回到 QWERTY 位置）。
    public static func keyCodeForCommandV() -> CGKeyCode {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return CGKeyCode(kVK_ANSI_V) }
        return keyCodeForCommandV(in: source)
    }

    /// 指定布局下的结果；测试用它检查没有启用的布局（V04）。
    static func keyCodeForCommandV(in source: TISInputSource) -> CGKeyCode {
        let ansiV = CGKeyCode(kVK_ANSI_V)
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return ansiV }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { raw -> CGKeyCode in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return ansiV }
            let commandState = UInt32((cmdKey >> 8) & 0xFF)
            for code in UInt16(0)..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), commandState, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
                if status == noErr, length == 1, chars[0] == UniChar(ascii: "v") { return code }
            }
            return ansiV
        }
    }
}

private extension UniChar {
    init(ascii character: Character) { self = UniChar(character.asciiValue ?? 0) }
}
