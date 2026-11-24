import AppKit

/// 复制、粘贴的提示音，来自应用资源里的两个音频文件。
///
/// 开关关着时什么都不创建；开着时每次播放临时建一个 `NSSound`，播完就放掉，空闲时不留音频资源。
/// 建声音和 `play()` 放在一个串行队列上：`play()` 会在调用的线程上等音频设备，第一次约 100 ms，之后每次 10–20 ms（L94）。
/// 通用设置中的开关即时生效。
@MainActor
final class SoundEffects {
    enum Effect: CaseIterable, Sendable {
        case copy, paste
    }

    static let shared = SoundEffects { AppPreferences.shared.soundEffectsEnabled }

    private let isEnabled: () -> Bool
    /// 正在播的声音，每种最多一个：连续复制时不叠加，也不排队。
    private var playing: [Effect: Playback] = [:]
    private static let queue = DispatchQueue(label: "com.mars.XPaste.sound", qos: .userInitiated)
    var volume: Float = 1

    init(isEnabled: @escaping () -> Bool) {
        self.isEnabled = isEnabled
    }

    func play(_ effect: Effect) {
        guard isEnabled(), playing[effect] == nil else { return }
        let playback = Playback()
        playing[effect] = playback
        #if DEBUG || BENCH
        debugCreatedCount += 1
        #endif
        let volume = volume
        Self.queue.async { [weak self] in
            // 读文件也放在串行队列上，不占主线程。
            playback.start(Self.soundData(for: effect), volume: volume) {
                Task { @MainActor in self?.finished(effect, playback) }
            }
        }
    }

    private func finished(_ effect: Effect, _ playback: Playback) {
        if playing[effect] === playback { playing[effect] = nil }
    }

    // MARK: 声音文件

    /// 应用资源里的音频数据（`Sounds/Copy.aiff`、`Sounds/Paste.aiff`）。每次播放现读，不常驻内存；读不到时不出声。
    nonisolated static func soundData(for effect: Effect) -> Data? {
        let name = switch effect {
        case .copy: "Copy"
        case .paste: "Paste"
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "aiff", subdirectory: "Sounds")
            ?? Bundle.main.url(forResource: name, withExtension: "aiff") else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    #if DEBUG || BENCH
    private(set) var debugCreatedCount = 0
    var debugPlayingCount: Int { playing.count }
    #endif
}

/// 一次播放。声音在串行队列上建好并开始播，主线程持有它直到播完。
private final class Playback: NSObject, NSSoundDelegate, @unchecked Sendable {
    // 只在串行队列上写一次；之后只有结束回调读，回调在 play() 之后才会来。
    private var sound: NSSound?
    private var onFinish: (@Sendable () -> Void)?

    func start(_ data: Data?, volume: Float, onFinish: @escaping @Sendable () -> Void) {
        self.onFinish = onFinish
        guard let data, let sound = NSSound(data: data) else { return finish() }
        sound.delegate = self
        sound.volume = volume
        self.sound = sound
        if !sound.play() { finish() }
    }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        finish()
    }

    private func finish() {
        sound?.delegate = nil
        onFinish?()
        onFinish = nil
    }
}
