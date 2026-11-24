import AppKit
import ClipboardKit

/// 把图片条目另存成临时 PNG，并在 item 上附上文件地址，这样能粘贴或拖进访达。
/// 原版多选图片复制时就是这样做的（Docs/08 第 9.16 节，L32）；拖出图片卡片也照此处理（L34）。
enum ImageFiles {
    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("XPaste-Images", isDirectory: true)

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    /// 对每个带图片、还没有文件地址的 item 附上文件地址；写文件失败的 item 原样保留。
    /// `name` 是文件名的前缀，通常是来源应用的名称。
    static func attachingFiles(to snapshot: ClipSnapshot, name: String?) -> ClipSnapshot {
        removeOldFiles()
        var changed = false
        let items = snapshot.items.map { item -> ClipItemSnapshot in
            guard item.data(for: ClipType.fileURL) == nil,
                  let data = item.data(for: ClipType.png) ?? item.data(for: ClipType.tiff),
                  let url = write(data, name: name) else { return item }
            changed = true
            return ClipItemSnapshot(representations: item.representations + [ClipRepresentation(type: ClipType.fileURL, data: Data(url.absoluteString.utf8))])
        }
        return changed ? ClipSnapshot(items: items, capturedAt: snapshot.capturedAt, sourceBundleID: snapshot.sourceBundleID, sourceName: snapshot.sourceName) : snapshot
    }

    /// 写成 `<名称> <日期 时间>.png`，同名时加序号。PNG 原样写，其他格式转成 PNG。
    static func write(_ data: Data, name: String?) -> URL? {
        let png: Data? = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? data
            : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
        guard let png else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // 文件名最长 255 字节（UTF-8）：名称部分按字符截到 180 字节以内，留出日期、序号和扩展名（审查 11）。
            var prefix = name?.isEmpty == false ? name! : String(localized: "图片")
            while prefix.utf8.count > 180 { prefix.removeLast() }
            let base = "\(prefix) \(dateFormatter.string(from: Date()))"
                .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            var url = folder.appendingPathComponent(base + ".png")
            var index = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = folder.appendingPathComponent("\(base) \(index).png")
                index += 1
            }
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            Log.files.error("另存图片失败: \(String(describing: error))")
            return nil
        }
    }

    /// 粘贴或拖放的接收方可能过一会儿才读文件，只清一天前的。
    private static func removeOldFiles() {
        let cutoff = Date().addingTimeInterval(-86_400)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where ((try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture) < cutoff {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
