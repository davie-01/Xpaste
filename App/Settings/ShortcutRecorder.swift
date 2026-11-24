import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    let title: String
    let shortcut: RecordedShortcut?
    let onChange: (RecordedShortcut?) -> String?
    let onRecording: (Bool) -> Void
    let onError: (String) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView { ShortcutRecorderView() }
    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.shortcut = shortcut
        view.setAccessibilityLabel(title)
        view.onChange = onChange
        view.onRecording = onRecording
        view.onError = onError
        view.refresh()
    }
    static func dismantleNSView(_ view: ShortcutRecorderView, coordinator: ()) { view.finishRecording() }
}

@MainActor
final class ShortcutRecorderView: NSView {
    var shortcut: RecordedShortcut?
    var onChange: (RecordedShortcut?) -> String? = { _ in nil }
    var onRecording: (Bool) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }
    private(set) var isRecording = false
    private var pendingFlags: NSEvent.ModifierFlags = []
    private let clearButton = NSButton()
    private var observers: [NSObjectProtocol] = []
    private var symbolicHotKeyToken: UnsafeMutableRawPointer?
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 121, height: 25) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        clearButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "清除快捷键"))
        clearButton.isBordered = false
        clearButton.imageScaling = .scaleProportionallyDown
        clearButton.target = self
        clearButton.action = #selector(clear)
        clearButton.setAccessibilityLabel(String(localized: "清除快捷键"))
        addSubview(clearButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit {
        if let symbolicHotKeyToken { PopSymbolicHotKeyMode(symbolicHotKeyToken) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidMoveToWindow() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        guard let window else { finishRecording(); return }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishRecording() }
            })
        }
    }
    override func layout() {
        super.layout()
        clearButton.frame = NSRect(x: bounds.width - 22, y: 3, width: 18, height: bounds.height - 6)
    }
    func refresh() {
        clearButton.isHidden = isRecording || shortcut == nil
        setAccessibilityValue(isRecording ? String(localized: "按下快捷键") : shortcut?.display ?? String(localized: "未设置"))
        setAccessibilityHelp(isRecording ? String(localized: "Esc 取消录制") : String(localized: "点按以录制快捷键"))
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()
        let label = isRecording ? (pendingFlags.isEmpty ? String(localized: "按下快捷键") : RecordedShortcut.symbols(pendingFlags)) : shortcut?.display ?? String(localized: "未设置")
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        let size = (label as NSString).size(withAttributes: attributes)
        let availableWidth = bounds.width - (clearButton.isHidden ? 0 : 23)
        (label as NSString).draw(at: NSPoint(x: max(5, (availableWidth - size.width) / 2), y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
    override func mouseDown(with event: NSEvent) { isRecording ? finishRecording() : beginRecording() }
    override func accessibilityPerformPress() -> Bool { beginRecording(); return true }
    func beginRecording() {
        guard !isRecording, window?.makeFirstResponder(self) == true else { return }
        isRecording = true
        pendingFlags = []
        onRecording(true)
        // 仅在本应用前台录制时暂挂系统组合，让系统冲突可交给校验；保留无障碍快捷键。
        // 未获辅助功能授权时系统可能忽略该请求，不主动索取权限。
        if NSApp.isActive, window?.isKeyWindow == true {
            symbolicHotKeyToken = PushSymbolicHotKeyMode(OptionBits(kHIHotKeyModeAllDisabledExceptUniversalAccess))
        }
        refresh()
    }
    func finishRecording() {
        guard isRecording else { return }
        isRecording = false
        pendingFlags = []
        if let token = symbolicHotKeyToken { PopSymbolicHotKeyMode(token); symbolicHotKeyToken = nil }
        onRecording(false)
        refresh()
    }
    override func resignFirstResponder() -> Bool { finishRecording(); return super.resignFirstResponder() }
    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return }
        pendingFlags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        refresh()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return false }
        receive(event)
        return true
    }
    override func keyDown(with event: NSEvent) {
        if isRecording { receive(event) }
        else if [36,49].contains(event.keyCode) { beginRecording() }
        else if [51,117].contains(event.keyCode) { clear() }
        else { super.keyDown(with: event) }
    }
    private func receive(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        if event.keyCode == 53 { finishRecording(); return }
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if event.keyCode == 48, flags.isSubset(of: .shift) {
            finishRecording()
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
            return
        }
        let value: RecordedShortcut? = [51,117].contains(event.keyCode) && flags.isEmpty ? nil : RecordedShortcut(keyCode: event.keyCode, flags: flags)
        finishRecording()
        if let error = onChange(value) { onError(error) }
    }
    @objc private func clear() {
        finishRecording()
        if let error = onChange(nil) { onError(error) }
    }
}
