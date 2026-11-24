import AppKit

/// 应用名称、版本和源码仓库，关于页与检查更新共用。
enum AppInfo {
    /// GitHub 上的仓库（“用户名/仓库名”）。还没建远端仓库时为 nil：关于页不显示 GitHub 按钮，检查更新提示尚未发布。
    static let repository: String? = nil

    static var name: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "XPaste" }
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }

    static var repositoryURL: URL? { repository.flatMap { URL(string: "https://github.com/\($0)") } }
    static var releasesURL: URL? { repository.flatMap { URL(string: "https://github.com/\($0)/releases") } }
}

/// 检查更新：只在用户点按钮时访问 GitHub 的“最新发布”接口，比较版本号，不在后台定时检查，也不自动下载。
enum UpdateChecker {
    enum Result: Equatable {
        case upToDate
        case available(version: String, page: URL)
        case notPublished
        case failed(String)
    }

    static func check(currentVersion: String = AppInfo.version, repository: String? = AppInfo.repository) async -> Result {
        guard let repository, let api = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { return .notPublished }
        var request = URLRequest(url: api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 仓库还没有任何发布时接口回 404。
            if status == 404 { return .notPublished }
            guard status == 200 else { return .failed(String(localized: "服务器返回了错误（\(status)）。")) }
            struct Release: Decodable { let tag_name: String; let html_url: String }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            guard isNewer(latest, than: currentVersion) else { return .upToDate }
            return .available(version: latest, page: URL(string: release.html_url) ?? AppInfo.releasesURL ?? api)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 按点分的数字逐段比较（“0.10.0” 比 “0.9.2” 新）；缺的段当 0，非数字的后缀（“-beta”）忽略。
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
