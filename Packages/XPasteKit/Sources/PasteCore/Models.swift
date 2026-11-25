import ClipboardKit
import Foundation

/// 列表里展示一张卡片所需的全部数据，不含原始剪贴板内容。
public struct ClipSummary: Sendable, Identifiable, Equatable {
    public let id: Int64
    public let uuid: String
    public let kind: ClipKind
    public let title: String?
    /// 文本类是正文开头一段；文件类是逐行的路径。
    public let previewText: String
    public let thumbnail: Data?
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    /// 全文的 UTF-16 码元数，与卡片底栏显示的口径一致。
    public let charCount: Int
    public let byteCount: Int
    /// 最近一次复制的时间；为空表示不在历史里（只留在 Pinboard）。
    public let timestamp: Date?
    public let createdAt: Date
    public let listID: String?
    public let sourceBundleID: String?
    public let sourceName: String?
    /// 来源应用标题栏颜色，由界面层算出后存入。
    public let sourceColorHex: String?
    /// 链接的页面标题，来自链接预览；还没取到或页面没有标题时为空。
    public let linkTitle: String?
    /// 链接条目的 `thumbnail` 里放的是什么。
    public let linkImage: LinkImageKind
    /// 文件条目复制时普通文件的总字节数（目录不计）。文件都不在了时预览显示它，和原版一样。
    public let fileBytes: Int64?
    /// 带 RTF 的文本条目开头一段的富文本（RTF 数据），卡片按它显示，和原版一样（L98）。
    public let richPreview: Data?

    public var filePaths: [String] {
        kind == .file ? previewText.split(separator: "\n").map(String.init) : []
    }
}

public struct Pinboard: Sendable, Identifiable, Equatable {
    public let id: String
    public var name: String
    public var colorHex: String
    public var sortIndex: Int
}

public struct ClipQuery: Sendable, Equatable {
    public enum Scope: Sendable, Equatable {
        case history
        case pinboard(String)
    }

    public var scope: Scope = .history
    public var text = ""
    public var kinds: Set<ClipKind> = []
    public var bundleIDs: Set<String> = []
    /// 历史范围内按所属 Pinboard 筛选。
    public var pinboardIDs: Set<String> = []
    public var since: Date?
    public var until: Date?
    /// 历史范围内同时包括只留在 Pinboard 里的条目（排在历史之后）。
    public var includePinnedOnly = false
    /// 条目名称包含这段文字（不区分 ASCII 大小写）。
    public var titleContains: String?

    public init(scope: Scope = .history, text: String = "") {
        self.scope = scope
        self.text = text
    }
}

/// 一张等待文字识别的图片。带上 uuid 是为了写回结果时确认还是同一条记录。
public struct OCRJob: Sendable, Equatable {
    public let id: Int64
    public let uuid: String
}

public enum LinkImageKind: Int, Sendable {
    case none = 0
    /// 站点图标，卡片上居中显示成小图标。
    case icon = 1
    /// 页面自带的配图，卡片上铺满正文区。
    case image = 2
}

/// 一条等待取页面信息的链接。带上 uuid 是为了写回结果时确认还是同一条记录。
public struct LinkJob: Sendable, Equatable {
    public let id: Int64
    public let uuid: String
    public let url: String
}

/// 从网页取回的标题和配图。`image` 是能被 ImageIO 解码的图像数据。
public struct LinkMetadata: Sendable, Equatable {
    public var title: String?
    public var image: Data?
    public var imageKind: LinkImageKind

    public init(title: String? = nil, image: Data? = nil, imageKind: LinkImageKind = .none) {
        self.title = title
        self.image = image
        self.imageKind = imageKind
    }
}

/// 删除前留下的完整副本，用于撤销。只存在于内存里。
public struct RestorableClip: Sendable {
    public let snapshot: ClipSnapshot
    public let title: String?
    public let listID: String?
    public let displayOrder: Int
    public let timestamp: Date?
    public let createdAt: Date
}

public enum RetentionPeriod: String, Sendable, CaseIterable {
    // 声明顺序就是从短到长的顺序：设置的滑块、“缩短期限要确认”都按它比较。3 个月、半年是 2026-11-25 用户要求加的。
    case day, week, month, threeMonths, sixMonths, year, forever

    public func cutoff(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .day: calendar.date(byAdding: .day, value: -1, to: now)
        case .week: calendar.date(byAdding: .day, value: -7, to: now)
        case .month: calendar.date(byAdding: .month, value: -1, to: now)
        case .threeMonths: calendar.date(byAdding: .month, value: -3, to: now)
        case .sixMonths: calendar.date(byAdding: .month, value: -6, to: now)
        case .year: calendar.date(byAdding: .year, value: -1, to: now)
        case .forever: nil
        }
    }
}

/// 自检结果：各项都应为 0。
public struct IntegrityReport: Sendable, Equatable {
    public var itemsWithoutData = 0
    public var dataWithoutItem = 0
    public var ftsWithoutItem = 0
    public var itemsWithoutFTS = 0
    public var assetRowsWithoutFile = 0
    public var filesWithoutAssetRow = 0
    public var pendingDeletes = 0

    public var isClean: Bool { self == IntegrityReport() }
}
