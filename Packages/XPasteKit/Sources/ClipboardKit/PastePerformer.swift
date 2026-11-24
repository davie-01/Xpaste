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

    /// 等触发热键的修饰键松开后再发事件，否则目标应用会收到叠加了多余修饰键的组合。
    /// 到期修饰键仍按着就不发（会变成别的快捷键）；发之前紧接着调用 `stillValid` 复核目标、剪贴板和请求（审查 01），不成立也不发。
    /// 返回是否发出了 ⌘V。
    public static func postPasteWhenModifiersReleased(timeout: Duration = .milliseconds(500),
                                                      stillValid: () -> Bool = { true }) async -> Bool {
        guard isTrusted else { return false }
        let held: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]
        let deadline = ContinuousClock.now + timeout
        while !CGEventSource.flagsState(.combinedSessionState).isDisjoint(with: held) {
            guard ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
        guard isTrusted, stillValid() else { return false }
        return postPaste()
    }

    @discardableResult
    public static func postPaste() -> Bool {
        guard isTrusted, let source = CGEventSource(stateID: .combinedSessionState) else { return false }
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
