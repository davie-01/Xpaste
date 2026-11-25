import AppKit

/// 应用名称、版本和源码仓库，给关于页用。
enum AppInfo {
    /// GitHub 上的仓库（“用户名/仓库名”）。为 nil 时关于页不显示 GitHub 按钮。更新源另写在 `App/Info.plist` 的 `SUFeedURL`。
    static let repository: String? = "davie-01/Xpaste"

    static var name: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "XPaste" }
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }

    static var repositoryURL: URL? { repository.flatMap { URL(string: "https://github.com/\($0)") } }
    static var releasesURL: URL? { repository.flatMap { URL(string: "https://github.com/\($0)/releases") } }
}
