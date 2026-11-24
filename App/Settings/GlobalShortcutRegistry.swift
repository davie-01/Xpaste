import Foundation

@MainActor
final class GlobalShortcutRegistry {
    private let activate: () -> Void
    private let stack: () -> Void
    private var registrations: [ShortcutAction: HotKey] = [:]
    private(set) var bindings: [ShortcutAction: RecordedShortcut] = [:]
    private var suspended = false
    private var suspendedActions: Set<ShortcutAction> = []
    private let actions: [ShortcutAction] = [.activate, .stack]

    init(activate: @escaping () -> Void, stack: @escaping () -> Void) {
        self.activate = activate
        self.stack = stack
    }
    /// 启动时逐项注册，保留成功项；某项被占用不应阻止用户修改或清除另一项。
    func load(_ settings: KeyboardSettings) throws {
        registrations.removeAll()
        bindings = desiredBindings(settings)
        var failures: [String] = []
        for action in actions {
            guard let shortcut = bindings[action] else { continue }
            do { registrations[action] = try register(shortcut, for: action) }
            catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { throw Failure(message: failures.joined(separator: "\n")) }
    }
    func apply(_ settings: KeyboardSettings) throws {
        let desired = desiredBindings(settings)
        let available = suspended ? suspendedActions : Set(registrations.keys)
        let changed = actions.filter { desired[$0] != bindings[$0] }
        // 之前被占用、未注册成功的组合，在再次保存或打开设置时重试；失败不影响其他项的修改。
        let retry = actions.filter { desired[$0] != nil && desired[$0] == bindings[$0] && !available.contains($0) }
        if !changed.isEmpty { try applyChanges(changed, desired: desired, available: available) }
        var failures: [String] = []
        for action in retry {
            guard let shortcut = desired[action] else { continue }
            do {
                let hotKey = try register(shortcut, for: action)
                if suspended { suspendedActions.insert(action) } else { registrations[action] = hotKey }
            } catch { failures.append(error.localizedDescription) }
        }
        if changed.isEmpty, !failures.isEmpty { throw Failure(message: failures.joined(separator: "\n")) }
    }
    private func applyChanges(_ changed: [ShortcutAction], desired: [ShortcutAction: RecordedShortcut],
                              available oldAvailable: Set<ShortcutAction>) throws {
        let old = bindings
        for action in changed { registrations[action] = nil }
        do {
            for action in changed {
                if let shortcut = desired[action] { registrations[action] = try register(shortcut, for: action) }
            }
            bindings = desired
            if suspended {
                suspendedActions.subtract(changed)
                suspendedActions.formUnion(registrations.keys)
                registrations.removeAll()
            }
        } catch {
            for action in changed { registrations[action] = nil }
            var restored = true
            if !suspended {
                for action in changed where oldAvailable.contains(action) {
                    guard let shortcut = old[action] else { continue }
                    do { registrations[action] = try register(shortcut, for: action) }
                    catch { restored = false }
                }
            }
            if !restored { throw Failure(message: String(localized: "新快捷键注册失败，原快捷键也未能恢复。请选择其他组合后重试。")) }
            throw error
        }
    }
    func setRecording(_ recording: Bool) throws {
        guard recording != suspended else { return }
        suspended = recording
        if recording {
            suspendedActions = Set(registrations.keys)
            registrations.removeAll()
        } else {
            var failures: [String] = []
            for action in actions where suspendedActions.contains(action) {
                guard let shortcut = bindings[action] else { continue }
                do { registrations[action] = try register(shortcut, for: action) }
                catch { failures.append(error.localizedDescription) }
            }
            suspendedActions.removeAll()
            if !failures.isEmpty { throw Failure(message: failures.joined(separator: "\n")) }
        }
    }
    private func desiredBindings(_ settings: KeyboardSettings) -> [ShortcutAction: RecordedShortcut] {
        Dictionary(uniqueKeysWithValues: actions.compactMap { action in settings[action].map { (action, $0) } })
    }
    private func register(_ shortcut: RecordedShortcut, for action: ShortcutAction) throws -> HotKey {
        guard let hotKey = HotKey(keyCode: Int(shortcut.keyCode), modifiers: shortcut.carbonModifiers,
                                  action: action == .activate ? activate : stack) else {
            throw Failure(message: String(localized: "无法注册“\(action.title)”；组合可能已被其他应用占用。原设置已保留。"))
        }
        return hotKey
    }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
