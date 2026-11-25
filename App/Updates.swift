import AppKit
import Sparkle

/// 应用内更新（Sparkle）。
///
/// - 更新源和公钥写在 `App/Info.plist`：每个正式 Release 附带 `appcast.xml`，地址取 GitHub 的
///   `releases/latest/download/appcast.xml`，始终指向最新的正式版（草稿不算）。更新包用 EdDSA 签名，打包时生成（见 `Tools/package.sh`）。
/// - 检查时机（用户决定，2026-11-24）：只在应用启动时静默检查一次，没有新版本什么都不显示；其余时候只在用户点“检查更新…”时联网。
///   不用 Sparkle 的定时检查（`SUEnableAutomaticChecks` 为 false），所以启动时自己调一次 `checkForUpdatesInBackground`，不会和它的定时器冲突。
/// - 启动时检查可以在“关于”里关掉（`AppPreferences.checksForUpdatesAtLaunch`）。
@MainActor
final class Updates: NSObject {
    static let shared = Updates()

    private var controller: SPUStandardUpdaterController?

    /// 自检和隔离测试配置下不启动更新：不联网、不弹窗。Debug 构建默认也不在启动时检查，
    /// 免得开发版被提示“更新”成正式版；要在 Debug 里测更新流程，用 `XPASTE_UPDATE_FEED` 指定一个本地更新源。
    private var isEnabled: Bool {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["XPASTE_SELFTEST"] == "1" { return false }
        if AppPreferences.testProfile != nil { return Self.debugFeed != nil }
        #endif
        return true
    }

    #if DEBUG
    /// Debug 构建里替换更新源（例如本机起的 http 服务上的 appcast.xml），用来端到端测更新流程。
    nonisolated fileprivate static var debugFeed: String? { ProcessInfo.processInfo.environment["XPASTE_UPDATE_FEED"] }
    #endif

    private var checksAtLaunch: Bool {
        #if DEBUG
        return Self.debugFeed != nil && AppPreferences.shared.checksForUpdatesAtLaunch
        #else
        return AppPreferences.shared.checksForUpdatesAtLaunch
        #endif
    }

    /// 应用启动完成后调用一次。
    func start() {
        guard isEnabled, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        controller.startUpdater()
        // 定时检查关着；万一用户以前的偏好里打开过，这里关回去，只留启动时这一次。
        controller.updater.automaticallyChecksForUpdates = false
        if checksAtLaunch {
            controller.updater.checkForUpdatesInBackground()
        }
    }

    /// 现在能不能开始一次手动检查（已有一次在进行时不能）。菜单项用它决定是否可点。
    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    /// 用户点“检查更新…”：后台应用要先到前台，Sparkle 的窗口才不会出在别的应用后面。
    func checkForUpdates() {
        guard let controller else { return }
        AppActivation.bringToFront()
        controller.checkForUpdates(nil)
    }
}

extension Updates: SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        #if DEBUG
        return Updates.debugFeed
        #else
        return nil
        #endif
    }
}

extension Updates: SPUStandardUserDriverDelegate {
    /// 后台应用（LSUIElement）必须声明支持温和提醒，否则 Sparkle 会警告：后台检查发现的更新可能出在别的窗口后面没人看见。
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// 启动时检查发现了新版本：照常由 Sparkle 弹出更新窗口，但先把应用带到前台，免得窗口被挡住。
    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard handleShowingUpdate, !state.userInitiated else { return }
        MainActor.assumeIsolated { AppActivation.bringToFront() }
    }
}
