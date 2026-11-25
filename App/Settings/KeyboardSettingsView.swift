import AppKit
import SwiftUI

struct KeyboardSettingsView: View {
    let preferences: AppPreferences
    let onChange: (KeyboardSettings) throws -> Void
    let onRecording: (Bool) -> String?
    @State private var settings: KeyboardSettings
    @State private var error: String?

    init(preferences: AppPreferences, onChange: @escaping (KeyboardSettings) throws -> Void,
         onRecording: @escaping (Bool) -> String?) {
        self.preferences = preferences
        self.onChange = onChange
        self.onRecording = onRecording
        _settings = State(initialValue: preferences.keyboardSettings)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            group([.activate, .stack])
            group([.nextPinboard, .previousPinboard])
            VStack(spacing: 0) {
                HStack {
                    Text("快速粘贴")
                    Spacer()
                    Picker("快速粘贴", selection: Binding(get: { settings.quickPaste }, set: { value in
                        var candidate = settings
                        candidate.quickPaste = value
                        error = save(candidate)
                    })) {
                        ForEach([ShortcutModifier.command, .control, .option], id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize()
                    Text("+ 1…9")
                }.frame(height: 36)
                Divider()
                HStack {
                    Text("纯文本模式")
                    Spacer()
                    Picker("纯文本模式", selection: Binding(get: { settings.plainText }, set: { value in
                        var candidate = settings
                        candidate.plainText = value
                        error = save(candidate)
                    })) {
                        ForEach(ShortcutModifier.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize()
                }.frame(height: 36)
            }.padding(.horizontal, 10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Spacer()
                Button("将快捷方式重置为默认…", action: reset)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).accessibilityLabel(error) }
        }
    }
    private func group(_ actions: [ShortcutAction]) -> some View {
        VStack(spacing: 0) {
            ForEach(actions) { action in
                HStack {
                    Text(action.title)
                    Spacer()
                    ShortcutRecorder(title: action.title, shortcut: settings[action], onChange: { value in
                        var candidate = settings
                        candidate[action] = value
                        return save(candidate)
                    }, onRecording: { active in
                        error = onRecording(active)
                    }, onError: { error = $0 }).frame(width: 121, height: 25)
                }.frame(height: 36)
                if action != actions.last { Divider() }
            }
        }.padding(.horizontal, 10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
    private func save(_ candidate: KeyboardSettings) -> String? {
        let message = SettingsActions.saveKeyboard(candidate, preferences: preferences, apply: onChange)
        if message == nil { settings = candidate }
        return message
    }
    private func reset() {
        let alert = NSAlert()
        alert.messageText = String(localized: "恢复所有默认快捷键？")
        alert.informativeText = String(localized: "四个快捷键和两种修饰键将恢复为默认设置。")
        alert.addButton(withTitle: String(localized: "取消"))
        alert.addButton(withTitle: String(localized: "重置"))
        // 回车和 Esc 都是“取消”；重置标红，只能点。
        alert.buttons[1].hasDestructiveAction = true
        WindowSharing.apply(to: alert.window)
        if alert.runModal(defaultButton: 0, cancelButton: 0) == .alertSecondButtonReturn { error = save(.defaults) }
    }
}
