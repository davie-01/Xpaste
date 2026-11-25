import AppKit

/// 文件类条目回放前的可访问性检查。
///
/// 系统会把本应用无权访问的文件 URL 从写入剪贴板的内容里静默去掉（“文稿”“桌面”“下载”等受保护文件夹）。
/// 只检查可读性不会触发授权询问，必须真正打开文件；这一步可能弹出系统对话框并阻塞，所以放在后台。
enum FileAccess {
    /// 读不了的原因分开记（审查 11）：已不存在、没有权限、其他读取错误（磁盘或网络卷出错等）。
    struct Result: Sendable {
        var missing: [URL] = []
        var denied: [URL] = []
        var unreadable: [URL] = []
        var isUsable: Bool { missing.isEmpty && denied.isEmpty && unreadable.isEmpty }
        var unusable: Set<URL> { Set(missing + denied + unreadable) }
    }

    static func check(_ urls: [URL]) async -> Result {
        await Task.detached(priority: .userInitiated) {
            let signpost = Log.signposter.beginInterval("files.check", id: Log.signposter.makeSignpostID(), "\(urls.count) 个")
            defer { Log.signposter.endInterval("files.check", signpost) }
            var result = Result()
            for url in urls {
                let fd = open(url.path, O_RDONLY | O_NONBLOCK)
                if fd >= 0 {
                    close(fd)
                } else {
                    switch errno {
                    case ENOENT, ENOTDIR: result.missing.append(url)
                    case EACCES, EPERM: result.denied.append(url)
                    default: result.unreadable.append(url)
                    }
                }
            }
            return result
        }.value
    }

    /// 系统按文件夹授权的那几个位置；文件在其中某个之内就返回它，否则返回文件所在的文件夹。
    static func protectedFolder(containing file: URL) -> URL {
        let path = file.standardizedFileURL.path
        let roots: [FileManager.SearchPathDirectory] = [.desktopDirectory, .documentDirectory, .downloadsDirectory]
        for root in roots.compactMap({ FileManager.default.urls(for: $0, in: .userDomainMask).first?.standardizedFileURL }) {
            if path.hasPrefix(root.path + "/") { return root }
        }
        return file.deletingLastPathComponent()
    }

    /// `opening` 为 true 时是打开、在 Finder 中显示这类操作，标题不说“粘贴”。
    @MainActor
    static func presentFailure(_ result: Result, opening: Bool = false) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if !result.denied.isEmpty {
            // 用系统的本地化名称（“桌面”而不是“Desktop”）。说的是要在系统设置里授权的那一层（“文稿”），不是它下面的子文件夹。
            let folder = FileManager.default.displayName(atPath: protectedFolder(containing: result.denied[0]).path)
            alert.messageText = opening ? String(localized: "无法访问文件") : String(localized: "无法粘贴文件")
            alert.informativeText = String(localized: "XPaste 没有访问“\(folder)”中文件的权限。请在“系统设置 › 隐私与安全性 › 文件与文件夹”中允许 XPaste 访问该文件夹，然后重试。")
            alert.addButton(withTitle: String(localized: "打开系统设置"))
            alert.addButton(withTitle: String(localized: "取消"))
        } else if !result.missing.isEmpty {
            alert.messageText = String(localized: "文件已不存在")
            alert.informativeText = result.missing.map(\.path).prefix(3).joined(separator: "\n")
            alert.addButton(withTitle: String(localized: "好"))
        } else {
            alert.messageText = String(localized: "读取文件时出错")
            alert.informativeText = result.unreadable.map(\.path).prefix(3).joined(separator: "\n")
            alert.addButton(withTitle: String(localized: "好"))
        }
        AppActivation.bringToFront()
        WindowSharing.apply(to: alert.window)
        if alert.runModal(defaultButton: 0, cancelButton: result.denied.isEmpty ? 0 : 1) == .alertFirstButtonReturn, !result.denied.isEmpty,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 完全磁盘访问是否已授予。系统没有查询接口，做法是打开几个只有授予了完全磁盘访问才能打开的文件夹：
/// 能打开就是已授权，返回“没有权限”（EPERM）就是未授权，不存在就试下一个。只打开、立刻关闭，不读内容。
/// 实测（2026-11-25）：没授权的应用打开这几个都是 EPERM，已授权的都能打开；不会弹授权提示。
/// 不用系统隐私数据库（TCC.db）：新系统里它不在原来的位置，打开返回“不存在”，会永远判成未授权。
/// 也不用别的应用的数据目录（~/Library/Containers/…）：访问它可能弹“访问其他应用的数据”的提示。
/// 要以应用本身启动结果才准；从终端直接运行可执行文件时，系统按终端的授权算。
enum FullDiskAccess {
    static let probes = ["Library/Safari", "Library/Mail", "Library/Messages"]

    static var isGranted: Bool {
        let home = NSHomeDirectory()
        for path in probes {
            let descriptor = open(home + "/" + path, O_RDONLY)
            if descriptor >= 0 {
                close(descriptor)
                return true
            }
            if errno == EPERM || errno == EACCES { return false }
        }
        return false
    }
}
