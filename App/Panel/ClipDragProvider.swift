import AppKit
import ClipboardKit
import PasteCore

/// 拖出卡片时的数据：起拖时只声明类型，接收方真正要某个类型时才读库、取外置文件、另存图片（审查 05、08）。
/// 这样起拖不再在主线程上同步准备全部内容，⌘A 全选几千条也能马上拖起来。
@MainActor
final class ClipDragProvider: NSObject, NSPasteboardItemDataProvider {
    enum Content {
        /// 一条的第一个 item（多文件条目另带老的文件名列表类型）。
        case single(ClipSummary)
        /// 多选里有文本时，合并后的文本，只放在第一个拖动项上（和粘贴一样，L35）。
        case composed([ClipSummary.ID])
    }

    private let store: HistoryStore
    private let content: Content
    private var cached: ClipSnapshot?
    private var loaded = false

    /// 接收方可能在拖动会话结束后才来取数据，提供者要活到剪贴板说用完为止。
    private static var alive: Set<ClipDragProvider> = []

    private init(store: HistoryStore, content: Content) {
        self.store = store
        self.content = content
    }

    /// 拖动项。`ids` 类型总是直接写上（面板内部和页签投放用），其余类型交给提供者。
    static func pasteboardItem(store: HistoryStore, content: Content, idsField: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(idsField, forType: ClipDrag.idsType)
        item.setData(Data(), forType: .init(CapturePolicy.selfMarker))
        let types = declaredTypes(store: store, content: content)
        guard !types.isEmpty else { return item }
        let provider = ClipDragProvider(store: store, content: content)
        if item.setDataProvider(provider, forTypes: types.map { NSPasteboard.PasteboardType($0) }) { alive.insert(provider) }
        return item
    }

    private static let filenamesType = "NSFilenamesPboardType"

    private static func declaredTypes(store: HistoryStore, content: Content) -> [String] {
        switch content {
        case .composed:
            return [ClipType.plainText, ClipType.rtf]
        case .single(let clip):
            guard let items = try? store.representationTypes(id: clip.id), var types = items.first else { return [] }
            // 图片另存成临时文件并带上地址，拖进访达会生成文件（L34）。
            if clip.kind == .image, !types.contains(ClipType.fileURL), types.contains(ClipType.png) || types.contains(ClipType.tiff) {
                types.append(ClipType.fileURL)
            }
            // 一个条目里有多个文件时，其余文件靠这个老类型带出去（访达等认它）。
            if items.filter({ $0.contains(ClipType.fileURL) }).count > 1 { types.append(filenamesType) }
            return types.filter { $0 != CapturePolicy.selfMarker && $0 != ClipDrag.idsType.rawValue }
        }
    }

    nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        // 系统在主线程上回调。
        nonisolated(unsafe) let item = item
        MainActor.assumeIsolated { provide(item: item, type: type.rawValue) }
    }

    nonisolated func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        MainActor.assumeIsolated { _ = Self.alive.remove(self) }
    }

    private func provide(item: NSPasteboardItem, type: String) {
        guard let snapshot = load() else { return }
        if type == Self.filenamesType {
            item.setPropertyList(snapshot.fileURLs.map(\.path), forType: .init(type))
        } else if let data = snapshot.items.first?.data(for: type) {
            item.setData(data, forType: .init(type))
        }
    }

    /// 第一次被要数据时读一次，之后复用。
    private func load() -> ClipSnapshot? {
        if loaded { return cached }
        loaded = true
        switch content {
        case .composed(let ids):
            cached = MultiSelection.compose(ids.compactMap { try? store.snapshot(id: $0) })
        case .single(let clip):
            guard var snapshot = try? store.snapshot(id: clip.id) else { return nil }
            // 和粘贴一样只交出还在的文件（审查 11）；拖动中不弹框，一个都不在时不给内容。
            let gone = Set(snapshot.fileURLs.filter { !FileManager.default.fileExists(atPath: $0.path) })
            if !gone.isEmpty {
                guard let kept = snapshot.removingFiles(gone) else { return nil }
                snapshot = kept
            }
            if clip.kind == .image { snapshot = ImageFiles.attachingFiles(to: snapshot, name: clip.sourceName) }
            cached = snapshot
        }
        return cached
    }
}
