import AppKit
import ClipboardKit
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

/// 剪贴板历史的持久化。所有写操作各自在一个事务里完成。
///
/// 语义与原版实测一致（Docs/归档/调研/08 第 9 节）：
/// - 历史视图是 `timestamp` 非空的条目；Pinboard 视图是 `listID` 等于该列表的条目，两者独立。
/// - 相同内容（checksum）全库只有一条记录，再次复制只更新 `timestamp`。
public final class HistoryStore: Sendable {
    private let db: DatabaseQueue
    private let assetDirectory: URL

    /// 超过这个大小的表示存成外置文件，不进数据库。
    static let inlineLimit = 256 * 1024
    static let previewTextLimit = 1_000
    /// 卡片只排版开头一段，富文本预览也只存这么多。
    static let richPreviewLimit = 600
    static let searchTextLimit = 200_000
    static let thumbnailMaxPixel = 640

    /// 库里有本版本不认识的迁移，说明是更新的版本写过的。
    public struct NewerDatabaseError: Error {}

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        assetDirectory = directory.appendingPathComponent("Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        var config = Configuration()
        config.foreignKeysEnabled = true
        // 删掉的内容在库文件里清零（R17）。系统 SQLite 默认是 FAST，被释放的溢出页不清，长文本删后还读得到。
        // 新建的库直接用增量整理模式；已有的库要等第一次整理（`compactIfNeeded`）时用 VACUUM 转过来（L92）。
        // 只在空库上设，已有的库打开时不写任何东西（N11：更新版本的库要原样留着）。
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
            if try Int.fetchOne(db, sql: "PRAGMA page_count") == 0 { try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL") }
        }
        db = try DatabaseQueue(path: directory.appendingPathComponent("db.sqlite").path, configuration: config)
        // 更新版本写过的库（N11）：不认识的结构不去碰，交给调用方提示后退出，库原样留给新版本。
        if try db.read(Self.migrator.hasBeenSuperseded) { throw NewerDatabaseError() }
        try Self.migrator.migrate(db)
        try recoverAfterLaunch()
    }

    // MARK: 结构

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE app (
                    id INTEGER PRIMARY KEY,
                    bundleID TEXT NOT NULL UNIQUE,
                    name TEXT
                );
                CREATE TABLE list (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    color TEXT NOT NULL,
                    sortIndex INTEGER NOT NULL,
                    createdAt REAL NOT NULL,
                    updatedAt REAL NOT NULL
                );
                CREATE TABLE item (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    uuid TEXT NOT NULL UNIQUE,
                    checksum TEXT NOT NULL UNIQUE,
                    kind TEXT NOT NULL,
                    title TEXT,
                    previewText TEXT NOT NULL,
                    thumbnail BLOB,
                    pixelWidth INTEGER,
                    pixelHeight INTEGER,
                    charCount INTEGER NOT NULL,
                    byteCount INTEGER NOT NULL,
                    timestamp REAL,
                    createdAt REAL NOT NULL,
                    updatedAt REAL NOT NULL,
                    listID TEXT REFERENCES list(id),
                    displayOrder INTEGER NOT NULL DEFAULT 0,
                    appID INTEGER REFERENCES app(id),
                    deviceID TEXT
                );
                CREATE INDEX item_on_timestamp ON item(timestamp DESC) WHERE timestamp IS NOT NULL;
                CREATE INDEX item_on_list ON item(listID, displayOrder) WHERE listID IS NOT NULL;
                CREATE TABLE item_data (
                    itemID INTEGER PRIMARY KEY REFERENCES item(id) ON DELETE CASCADE,
                    payload BLOB NOT NULL
                );
                CREATE TABLE item_asset (
                    name TEXT PRIMARY KEY,
                    itemID INTEGER NOT NULL REFERENCES item(id) ON DELETE CASCADE
                );
                CREATE TABLE pending_asset_delete (name TEXT PRIMARY KEY);
                CREATE VIRTUAL TABLE item_fts USING fts5(content, tokenize='trigram');
                """)
        }
        migrator.registerMigration("v2-app-color") { db in
            try db.execute(sql: "ALTER TABLE app ADD COLUMN color TEXT")
        }
        migrator.registerMigration("v3-ocr") { db in
            // ocrState：0 待识别，1 已完成，2 识别失败（不再重试）。只对图片条目有意义。
            try db.execute(sql: """
                ALTER TABLE item ADD COLUMN ocrText TEXT;
                ALTER TABLE item ADD COLUMN ocrState INTEGER NOT NULL DEFAULT 0;
                CREATE INDEX item_on_ocr_pending ON item(id) WHERE kind = 'image' AND ocrState = 0;
                """)
        }
        migrator.registerMigration("v4-link") { db in
            // linkState：0 待取，1 已取过，2 不取（不是公开网址）。只对链接条目有意义。
            // linkImageKind 见 LinkImageKind；配图本身放在 thumbnail 列。
            try db.execute(sql: """
                ALTER TABLE item ADD COLUMN linkTitle TEXT;
                ALTER TABLE item ADD COLUMN linkImageKind INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE item ADD COLUMN linkState INTEGER NOT NULL DEFAULT 0;
                CREATE INDEX item_on_link_pending ON item(id) WHERE kind = 'link' AND linkState = 0;
                """)
        }
        migrator.registerMigration("v5-file-bytes") { db in
            // 文件条目复制时的大小；之前的条目为空。
            try db.execute(sql: "ALTER TABLE item ADD COLUMN fileBytes INTEGER")
        }
        migrator.registerMigration("v6-rich-preview") { db in
            // 带 RTF 的文本条目开头一段的富文本，卡片按它显示（L98）；之前的条目为空，仍显示纯文本。
            try db.execute(sql: "ALTER TABLE item ADD COLUMN richPreview BLOB")
        }
        migrator.registerMigration("v7-app-icon") { db in
            // 来源应用的图标（PNG），应用卸载后卡片仍显示原来的图标（L42）。
            try db.execute(sql: "ALTER TABLE app ADD COLUMN icon BLOB")
        }
        migrator.registerMigration("v8-rich-refresh") { db in
            // richState：0 卡片缓存待补写，1 已处理。只对文本条目有意义（L179）：只有 HTML 的条目入库时标 0，
            // 由应用在主线程转换 HTML 后补写（HTML 转换要用 WebKit，入库的后台线程做不了）；其余入库时已算好，标 1。
            // 1.0.7 时这里还把已有的文本条目全部置 0、按新规则重算；只有用户自己的库用过，都已跑完，
            // 2026-11-28 去掉了这一句（用户决定）。已执行过的库不受影响，没执行过的旧库里的条目不再重算。
            try db.execute(sql: """
                ALTER TABLE item ADD COLUMN richState INTEGER NOT NULL DEFAULT 1;
                CREATE INDEX item_on_rich_pending ON item(id) WHERE kind = 'text' AND richState = 0;
                """)
        }
        return migrator
    }

    // MARK: 写入

    /// 保存一次复制。相同内容已存在时只更新时间，让它回到历史最前。
    @discardableResult
    public func record(_ snapshot: ClipSnapshot, now: Date = Date()) throws -> ClipSummary {
        try store(snapshot, now: now) { db, id, existed in
            if existed {
                try db.execute(sql: "UPDATE item SET timestamp = ?, updatedAt = ? WHERE id = ?", arguments: [now, now, id])
            }
        }
    }

    /// 写入一条内容的共同路径（审查 03）。查重、写入和取摘要在同一个事务里：
    /// - 两个调用同时写相同内容时，后提交的一方在事务里看到前一方的记录，按“已存在”处理，不会撞唯一约束；
    /// - 摘要在提交前取好，提交之后不再有会失败的步骤，也就不会在提交后误删已被引用的外置文件；
    /// - 条目在两步之间被删掉时，按新内容重新写入，不会强制解包出错。
    /// `apply` 在同一事务里调整这条记录：`existed` 表示内容原本就在库里。
    private func store(_ snapshot: ClipSnapshot, now: Date,
                       apply: (Database, _ id: Int64, _ existed: Bool) throws -> Void) throws -> ClipSummary {
        // 常见情况是重复复制同一内容：先在一个事务里看看已有没有，有就不必编码内容、写外置文件。
        if let summary = try db.write({ db -> ClipSummary? in
            guard let id = try Self.existingID(db, snapshot) else { return nil }
            try apply(db, id, true)
            return try Self.requireSummary(db, id: id)
        }) {
            return summary
        }
        let prepared = try prepare(snapshot)
        let result: (summary: ClipSummary, inserted: Bool)
        do {
            result = try db.write { db -> (ClipSummary, Bool) in
                let (id, existed) = try Self.insertOrReuse(db, prepared, now: now)
                try apply(db, id, existed)
                return (try Self.requireSummary(db, id: id), !existed)
            }
        } catch {
            removeAssetFiles(prepared.assetNames)
            throw error
        }
        // 用了已有记录：这次写的外置文件没人引用。
        if !result.inserted { removeAssetFiles(prepared.assetNames) }
        return result.summary
    }

    /// 编码好、外置文件已写出、还没进库的一条内容。
    private struct PreparedClip {
        let snapshot: ClipSnapshot
        let payload: Data
        let assetNames: [String]
        let derived: Derived
    }

    /// 在事务外做耗时的部分：编码内容、写外置文件、生成缩略图和摘要文字。失败时回收已写的文件。
    private func prepare(_ snapshot: ClipSnapshot) throws -> PreparedClip {
        var assetNames: [String] = []
        do {
            let payload = try encodePayload(of: snapshot, assetNames: &assetNames)
            return PreparedClip(snapshot: snapshot, payload: payload, assetNames: assetNames, derived: Derived(snapshot: snapshot))
        } catch {
            removeAssetFiles(assetNames)
            throw error
        }
    }

    /// 事务里写入一条准备好的内容；相同内容已在库里时不写，返回已有的 id（`existed` 为真）。
    private static func insertOrReuse(_ db: Database, _ prepared: PreparedClip, now: Date) throws -> (id: Int64, existed: Bool) {
        let snapshot = prepared.snapshot, derived = prepared.derived
        // 编码期间别的调用可能已经写进了相同内容。
        if let id = try existingID(db, snapshot) { return (id, true) }
        var appID: Int64?
        if let bundleID = snapshot.sourceBundleID {
            try db.execute(sql: """
                INSERT INTO app (bundleID, name) VALUES (?, ?)
                ON CONFLICT(bundleID) DO UPDATE SET name = COALESCE(excluded.name, name)
                """, arguments: [bundleID, snapshot.sourceName])
            appID = try Int64.fetchOne(db, sql: "SELECT id FROM app WHERE bundleID = ?", arguments: [bundleID])
        }
        try db.execute(sql: """
            INSERT INTO item (uuid, checksum, kind, previewText, thumbnail, pixelWidth, pixelHeight,
                              charCount, byteCount, timestamp, createdAt, updatedAt, appID, fileBytes, richPreview, richState)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                snapshot.id.uuidString, snapshot.fingerprint, snapshot.kind.rawValue, derived.previewText,
                derived.thumbnail, derived.pixelWidth, derived.pixelHeight, derived.charCount,
                snapshot.byteCount, now, now, now, appID, derived.fileBytes, derived.richPreview, derived.richState,
            ])
        let id = db.lastInsertedRowID
        try db.execute(sql: "INSERT INTO item_data (itemID, payload) VALUES (?, ?)", arguments: [id, prepared.payload])
        for name in prepared.assetNames {
            try db.execute(sql: "INSERT INTO item_asset (name, itemID) VALUES (?, ?)", arguments: [name, id])
        }
        try db.execute(sql: "INSERT INTO item_fts (rowid, content) VALUES (?, ?)",
                       arguments: [id, searchContent(title: nil, text: derived.searchText, source: snapshot.sourceName)])
        return (id, false)
    }

    private static func existingID(_ db: Database, _ snapshot: ClipSnapshot) throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT id FROM item WHERE checksum = ?", arguments: [snapshot.fingerprint])
    }

    struct MissingItemError: Error {}

    /// 事务里取摘要；取不到说明记录不在了，抛错让整个事务回滚。
    private static func requireSummary(_ db: Database, id: Int64) throws -> ClipSummary {
        guard let summary = try summary(db, id: id) else { throw MissingItemError() }
        return summary
    }

    private static func summary(_ db: Database, id: Int64) throws -> ClipSummary? {
        try Row.fetchOne(db, sql: """
            SELECT item.*, app.bundleID AS bundleID, app.name AS appName, app.color AS appColor
            FROM item LEFT JOIN app ON app.id = item.appID WHERE item.id = ?
            """, arguments: [id]).map(Self.summary(from:))
    }

    /// 粘贴后调用：让条目回到历史最前。
    public func touch(id: Int64, now: Date = Date()) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE item SET timestamp = ?, updatedAt = ? WHERE id = ?", arguments: [now, now, id])
        }
    }

    /// 多选粘贴后调用：这几条一起回到历史最前，彼此的先后顺序不变。`ids` 按面板上的显示顺序给出。
    public func touch(ids: [Int64], now: Date = Date()) throws {
        try db.write { db in
            for (offset, id) in ids.enumerated() {
                // 排在前面的时间稍晚一点。
                let time = now.addingTimeInterval(-Double(offset) * 0.001)
                try db.execute(sql: "UPDATE item SET timestamp = ?, updatedAt = ? WHERE id = ?", arguments: [time, time, id])
            }
        }
    }

    public func setTitle(_ title: String?, for id: Int64, now: Date = Date()) throws {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        try db.write { db in
            try db.execute(sql: "UPDATE item SET title = ?, updatedAt = ? WHERE id = ?",
                           arguments: [title?.isEmpty == false ? title : nil, now, id])
            try Self.rebuildSearchContent(db, id: id)
        }
    }

    /// 编辑保存：用新内容替换条目的全部表示。位置、时间、名称和所属 Pinboard 都不变（原版实测，Docs/归档/调研/08 第 9.14 节）。
    /// 条目已不存在时返回 nil。
    @discardableResult
    public func replaceContent(of id: Int64, with snapshot: ClipSnapshot, now: Date = Date()) throws -> ClipSummary? {
        var assetNames: [String] = []
        let payload: Data
        do {
            payload = try encodePayload(of: snapshot, assetNames: &assetNames)
        } catch {
            removeAssetFiles(assetNames)
            throw error
        }

        let derived = Derived(snapshot: snapshot)
        do {
            let found = try db.write { db -> Bool in
                guard let uuid = try String.fetchOne(db, sql: "SELECT uuid FROM item WHERE id = ?", arguments: [id]) else { return false }
                // 原版允许编辑出两条一样的内容。checksum 列是唯一的，撞上别的条目时给这一条带上自己的 uuid；
                // 之后再复制同样的内容，命中的是没带后缀的那条。
                let taken = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM item WHERE checksum = ? AND id != ?)",
                                              arguments: [snapshot.fingerprint, id]) ?? false
                let checksum = taken ? snapshot.fingerprint + "#" + uuid : snapshot.fingerprint
                try db.execute(sql: "INSERT OR IGNORE INTO pending_asset_delete SELECT name FROM item_asset WHERE itemID = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM item_asset WHERE itemID = ?", arguments: [id])
                // 内容换了，识别结果和链接信息都作废，重新排队。
                try db.execute(sql: """
                    UPDATE item SET checksum = ?, kind = ?, previewText = ?, thumbnail = ?, pixelWidth = ?, pixelHeight = ?,
                                    charCount = ?, byteCount = ?, updatedAt = ?, richPreview = ?, richState = ?,
                                    ocrText = NULL, ocrState = 0, linkTitle = NULL, linkImageKind = 0, linkState = 0
                    WHERE id = ?
                    """, arguments: [checksum, snapshot.kind.rawValue, derived.previewText, derived.thumbnail, derived.pixelWidth,
                                     derived.pixelHeight, derived.charCount, snapshot.byteCount, now, derived.richPreview, derived.richState, id])
                try db.execute(sql: "UPDATE item_data SET payload = ? WHERE itemID = ?", arguments: [payload, id])
                for name in assetNames {
                    try db.execute(sql: "INSERT INTO item_asset (name, itemID) VALUES (?, ?)", arguments: [name, id])
                }
                try Self.rebuildSearchContent(db, id: id)
                return true
            }
            guard found else {
                removeAssetFiles(assetNames)
                return nil
            }
        } catch {
            removeAssetFiles(assetNames)
            throw error
        }
        drainPendingAssetDeletes()
        return try summary(id: id)
    }

    // MARK: 只有 HTML 的文本条目补写卡片缓存（v8-rich-refresh）

    /// 一条待补写的文本条目。`checksum` 用来认出处理期间内容被换掉（同一条被编辑、重新复制）的情况。
    public struct RichRefreshJob: Sendable, Equatable {
        public let id: Int64
        public let uuid: String
        public let checksum: String
    }

    /// 最新的一条待补写的文本条目（只有 HTML、入库时没能生成卡片缓存的）。
    public func nextTextAwaitingRichRefresh() throws -> RichRefreshJob? {
        try db.read { db in
            try Row.fetchOne(db, sql: "SELECT id, uuid, checksum FROM item WHERE kind = 'text' AND richState = 0 ORDER BY id DESC LIMIT 1")
                .map { RichRefreshJob(id: $0["id"], uuid: $0["uuid"], checksum: $0["checksum"]) }
        }
    }

    public enum RichRefreshStep: Sendable, Equatable {
        /// 已处理完，没有要写的（已有缓存、没有 HTML、数据读不出来）。
        case done
        /// 只有 HTML、还没有卡片缓存：要在主线程转换（WebKit），再用 `finishRichRefresh` 写入。
        case needsHTML(Data)
    }

    /// 取出待补写条目的 HTML（可在后台调用）：只有 HTML、还没有卡片缓存的交回 HTML，由主线程转换后用
    /// `finishRichRefresh` 写入，字符数仍按纯文本（用户决定）；其余只标记已处理。
    /// 写入都带 `uuid`、`checksum` 和 `richState = 0` 条件：处理期间条目被删、内容被换掉时什么都不写。
    public func refreshRich(_ job: RichRefreshJob) throws -> RichRefreshStep {
        // 读出的快照和条目是否还是同一条、内容有没有换过，由写入时的条件保证。
        guard let snapshot = try snapshot(id: job.id), let item = snapshot.items.first else {
            try markRichRefreshed(job)
            return .done
        }
        let hasPreview = try db.read { db in
            try Bool.fetchOne(db, sql: "SELECT richPreview IS NOT NULL FROM item WHERE id = ?", arguments: [job.id]) ?? true
        }
        if !hasPreview, RichText.decode(item) == nil, let html = item.data(for: ClipType.html) { return .needsHTML(html) }
        try markRichRefreshed(job)
        return .done
    }

    /// 写入主线程从 HTML 转好的卡片缓存（`data` 由 `richPreviewData(from:)` 生成，转换失败传 nil）并标记已处理。
    /// 只在还没有缓存时写，不覆盖。返回是否写入了缓存。
    @discardableResult
    public func finishRichRefresh(_ job: RichRefreshJob, richPreview data: Data?) throws -> Bool {
        try db.write { db in
            var filled = false
            if let data {
                try db.execute(sql: "UPDATE item SET richPreview = ? WHERE id = ? AND uuid = ? AND checksum = ? AND richState = 0 AND richPreview IS NULL",
                               arguments: [data, job.id, job.uuid, job.checksum])
                filled = db.changesCount > 0
            }
            try Self.markRichRefreshed(db, job)
            return filled
        }
    }

    private func markRichRefreshed(_ job: RichRefreshJob) throws {
        try db.write { db in try Self.markRichRefreshed(db, job) }
    }

    /// 内容换过的不标：新内容入库时已重新判断过要不要补算。
    private static func markRichRefreshed(_ db: Database, _ job: RichRefreshJob) throws {
        try db.execute(sql: "UPDATE item SET richState = 1 WHERE id = ? AND uuid = ? AND checksum = ?", arguments: [job.id, job.uuid, job.checksum])
    }

    // MARK: 图片文字识别

    /// 最新的一张还没识别过的图片。
    public func nextImageAwaitingOCR() throws -> OCRJob? {
        try db.read { db in
            try Row.fetchOne(db, sql: "SELECT id, uuid FROM item WHERE kind = 'image' AND ocrState = 0 ORDER BY id DESC LIMIT 1")
                .map { OCRJob(id: $0["id"], uuid: $0["uuid"]) }
        }
    }

    /// 图片条目的原始图像数据。
    public func imageData(id: Int64) throws -> Data? {
        try snapshot(id: id)?.imageData
    }

    /// 识别语言改了之后重新识别全部图片。旧结果保留到新结果写入为止，期间搜索照常可用。返回排队的张数。
    @discardableResult
    public func requeueTextRecognition() throws -> Int {
        try db.write { db in
            try db.execute(sql: "UPDATE item SET ocrState = 0 WHERE kind = 'image' AND ocrState != 0")
            return db.changesCount
        }
    }

    /// 写入识别结果并更新搜索索引；`text` 为 nil 表示识别失败。
    /// 条目在识别期间被删掉时什么都不写，返回 false：迟到的结果不能让已删除的内容回到索引里。
    @discardableResult
    public func setOCRResult(_ text: String?, for job: OCRJob) throws -> Bool {
        try db.write { db in
            try db.execute(sql: "UPDATE item SET ocrText = ?, ocrState = ? WHERE id = ? AND uuid = ? AND ocrState = 0",
                           arguments: [text.map { String($0.prefix(Self.searchTextLimit)) }, text == nil ? 2 : 1, job.id, job.uuid])
            guard db.changesCount > 0 else { return false }
            try Self.rebuildSearchContent(db, id: job.id)
            return true
        }
    }

    // MARK: 链接预览

    /// 最新的一条还没取过页面信息的链接。`skipped` 是这次运行里取失败、留到下次启动再试的条目。
    public func nextLinkAwaitingMetadata(excluding skipped: Set<Int64> = []) throws -> LinkJob? {
        try db.read { db in
            let cursor = try Row.fetchCursor(db, sql: "SELECT id, uuid, previewText FROM item WHERE kind = 'link' AND linkState = 0 ORDER BY id DESC")
            while let row = try cursor.next() {
                let id: Int64 = row["id"]
                if !skipped.contains(id) { return LinkJob(id: id, uuid: row["uuid"], url: row["previewText"]) }
            }
            return nil
        }
    }

    /// 写入页面标题和配图，标题进搜索索引；`metadata` 为 nil 表示这条链接不取（不是公开网址）。
    /// 条目在取的过程中被删掉时什么都不写，返回 false。
    @discardableResult
    public func setLinkMetadata(_ metadata: LinkMetadata?, for job: LinkJob) throws -> Bool {
        var kind = metadata?.imageKind ?? .none
        var thumbnail: Data?
        if kind != .none, let data = metadata?.image, let source = CGImageSourceCreateWithData(data as CFData, nil) {
            thumbnail = Derived.thumbnail(from: source)
        }
        if thumbnail == nil { kind = .none }
        let title = metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try db.write { db in
            try db.execute(sql: """
                UPDATE item SET linkTitle = ?, thumbnail = ?, linkImageKind = ?, linkState = ?
                WHERE id = ? AND uuid = ? AND linkState = 0
                """, arguments: [title?.isEmpty == false ? title.map { String($0.prefix(500)) } : nil, thumbnail, kind.rawValue,
                                 metadata == nil ? 2 : 1, job.id, job.uuid])
            guard db.changesCount > 0 else { return false }
            try Self.rebuildSearchContent(db, id: job.id)
            return true
        }
    }

    // MARK: 删除

    /// 在历史页签删除：未固定的整条删除；已固定的只从历史移出，Pinboard 里保留。
    public func removeFromHistory(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try db.write { db in
            let marks = Self.marks(ids.count)
            try db.execute(sql: "UPDATE item SET timestamp = NULL WHERE listID IS NOT NULL AND id IN (\(marks))",
                           arguments: StatementArguments(ids))
            let doomed = try Int64.fetchAll(db, sql: "SELECT id FROM item WHERE listID IS NULL AND id IN (\(marks))",
                                            arguments: StatementArguments(ids))
            try Self.deleteRows(db, ids: doomed)
        }
        drainPendingAssetDeletes()
    }

    /// 在 Pinboard 页签删除：整条删除。
    public func deleteFromPinboard(ids: [Int64]) throws {
        try db.write { db in try Self.deleteRows(db, ids: ids) }
        drainPendingAssetDeletes()
    }

    /// “删除历史”：未固定的全部删除，已固定的只从历史移出。
    public func eraseHistory() throws {
        try clearHistory(before: nil)
    }

    /// 按保留期限清理，规则与“删除历史”相同，只作用于早于截止时间的条目。
    public func applyRetention(_ period: RetentionPeriod, now: Date = Date()) throws {
        guard let cutoff = period.cutoff(from: now) else { return }
        try clearHistory(before: cutoff)
    }

    private func clearHistory(before cutoff: Date?) throws {
        try db.write { db in
            let condition = cutoff == nil ? "timestamp IS NOT NULL" : "timestamp < ?"
            let arguments: StatementArguments = cutoff.map { [$0] } ?? []
            let doomed = try Int64.fetchAll(db, sql: "SELECT id FROM item WHERE listID IS NULL AND \(condition)", arguments: arguments)
            try Self.deleteRows(db, ids: doomed)
            try db.execute(sql: "UPDATE item SET timestamp = NULL WHERE listID IS NOT NULL AND \(condition)", arguments: arguments)
        }
        drainPendingAssetDeletes()
    }

    /// 放掉 SQLite 的页缓存和语句缓存（面板收起一阵后调用，轻量化）。下次查询时再按需读回。
    public func releaseMemory() {
        db.releaseMemory()
    }

    /// 按需整理库文件（L92）：删掉的内容留下的空闲页平时留着给新内容复用，不每次清理都整理；
    /// 只有空闲页至少 4 MB、而且占库文件四分之一以上时，才把它们还给文件系统。
    /// 库还不是增量整理模式时（旧版本建的库）做一次 VACUUM 顺带转过来，之后只做 `incremental_vacuum`，只动空闲页。
    /// 返回是否整理了。由保留期限的定时清理之后在后台调用。
    @discardableResult
    public func compactIfNeeded(minimumFreeBytes: Int = 4 << 20, minimumFreeRatio: Double = 0.25) throws -> Bool {
        try db.writeWithoutTransaction { db in
            let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4_096
            let pages = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let free = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
            guard pages > 0, free * pageSize >= minimumFreeBytes, Double(free) / Double(pages) >= minimumFreeRatio else { return false }
            if try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") == 2 {
                try db.execute(sql: "PRAGMA incremental_vacuum")
            } else {
                try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
                try db.execute(sql: "VACUUM")
            }
            return true
        }
    }

    /// 同一事务里删掉记录、索引并登记外置文件；文件在提交后由 `drainPendingAssetDeletes` 删除。
    private static func deleteRows(_ db: Database, ids: [Int64]) throws {
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            let marks = marks(chunk.count)
            let arguments = StatementArguments(chunk)
            try db.execute(sql: "INSERT OR IGNORE INTO pending_asset_delete SELECT name FROM item_asset WHERE itemID IN (\(marks))", arguments: arguments)
            try db.execute(sql: "DELETE FROM item_fts WHERE rowid IN (\(marks))", arguments: arguments)
            try db.execute(sql: "DELETE FROM item WHERE id IN (\(marks))", arguments: arguments)
        }
    }

    // MARK: 撤销

    /// 删除之前调用，取回足以原样恢复这些条目的数据。内容读不出来的条目会被跳过。
    public func restorable(ids: [Int64]) throws -> [RestorableClip] {
        try ids.compactMap { id in
            guard let row = try db.read({ db in
                try Row.fetchOne(db, sql: "SELECT title, listID, displayOrder, timestamp, createdAt FROM item WHERE id = ?", arguments: [id])
            }), let snapshot = try snapshot(id: id) else { return nil }
            return RestorableClip(snapshot: snapshot, title: row["title"], listID: row["listID"],
                                  displayOrder: row["displayOrder"], timestamp: row["timestamp"], createdAt: row["createdAt"])
        }
    }

    /// 撤销删除：条目回到原来的位置（时间、标题、所属 Pinboard 都恢复）。返回恢复后的条目 ID。
    /// 整批在一个事务里提交，任何一条失败都不留下半批（审查 04）；失败时这次写出的外置文件全部回收。
    /// 删除之后又复制过相同内容时，两者合成一条：保留较新的时间，名称、所属 Pinboard 以现在这条为准，现在没有的才用删除前的。
    @discardableResult
    public func restore(_ clips: [RestorableClip]) throws -> [Int64] {
        var prepared: [PreparedClip] = []
        do {
            for clip in clips { prepared.append(try prepare(clip.snapshot)) }
        } catch {
            prepared.forEach { removeAssetFiles($0.assetNames) }
            throw error
        }
        let result: [(id: Int64, existed: Bool)]
        do {
            result = try db.write { db in
                try zip(clips, prepared).enumerated().map { index, pair in
                    let (clip, prepared) = pair
                    #if DEBUG
                    if index == debugFailRestoreAt { throw MissingItemError() }
                    #endif
                    let (id, existed) = try Self.insertOrReuse(db, prepared, now: clip.timestamp ?? clip.createdAt)
                    // 所属 Pinboard 可能在这期间被删了，那就不再恢复归属。
                    let listExists = try clip.listID.map { try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM list WHERE id = ?)", arguments: [$0]) ?? false } ?? false
                    let listID = listExists ? clip.listID : nil
                    if existed {
                        try db.execute(sql: """
                            UPDATE item SET title = COALESCE(title, ?),
                                            displayOrder = CASE WHEN listID IS NULL THEN ? ELSE displayOrder END,
                                            listID = COALESCE(listID, ?),
                                            timestamp = CASE WHEN timestamp IS NULL OR ? IS NULL THEN COALESCE(timestamp, ?) ELSE MAX(timestamp, ?) END,
                                            createdAt = MIN(createdAt, ?)
                            WHERE id = ?
                            """, arguments: [clip.title, clip.displayOrder, listID, clip.timestamp, clip.timestamp, clip.timestamp, clip.createdAt, id])
                    } else {
                        try db.execute(sql: "UPDATE item SET title = ?, listID = ?, displayOrder = ?, timestamp = ?, createdAt = ? WHERE id = ?",
                                       arguments: [clip.title, listID, clip.displayOrder, clip.timestamp, clip.createdAt, id])
                    }
                    try Self.rebuildSearchContent(db, id: id)
                    return (id, existed)
                }
            }
        } catch {
            prepared.forEach { removeAssetFiles($0.assetNames) }
            throw error
        }
        for (prepared, outcome) in zip(prepared, result) where outcome.existed { removeAssetFiles(prepared.assetNames) }
        return result.map(\.id)
    }

    #if DEBUG
    /// 测试用：恢复第 n 条（从 0 数）时让事务失败。
    nonisolated(unsafe) var debugFailRestoreAt: Int?
    #endif

    // MARK: Pinboard

    public func pinboards() throws -> [Pinboard] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, name, color, sortIndex FROM list ORDER BY sortIndex, createdAt").map {
                Pinboard(id: $0["id"], name: $0["name"], colorHex: $0["color"], sortIndex: $0["sortIndex"])
            }
        }
    }

    /// 每个 Pinboard 里的条目数。
    public func pinboardItemCounts() throws -> [String: Int] {
        try db.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT listID, COUNT(*) AS n FROM item WHERE listID IS NOT NULL GROUP BY listID")
                .map { ($0["listID"] as String, $0["n"] as Int) })
        }
    }

    /// 新建条目（MCP 等不经过剪贴板的入口）。不带 Pinboard 时与复制一样进入历史，相同内容回到最前。
    /// 带 Pinboard 时只固定、不进历史；历史里已有相同内容就固定已有条目，不改它在历史里的位置。
    @discardableResult
    public func createItem(_ snapshot: ClipSnapshot, pinTo listID: String? = nil, now: Date = Date()) throws -> ClipSummary {
        guard let listID else { return try record(snapshot, now: now) }
        // 查重、写入和固定在同一个事务里（审查 03）。
        return try store(snapshot, now: now) { db, id, existed in
            // 新写入的只固定、不进历史。
            if !existed { try db.execute(sql: "UPDATE item SET timestamp = NULL WHERE id = ?", arguments: [id]) }
            let current = try String.fetchOne(db, sql: "SELECT listID FROM item WHERE id = ?", arguments: [id])
            if current != listID { try Self.pin(db, ids: [id], to: listID, now: now) }
        }
    }

    @discardableResult
    public func createPinboard(name: String, colorHex: String, now: Date = Date()) throws -> Pinboard {
        try db.write { db in
            let id = UUID().uuidString
            let next = (try Int.fetchOne(db, sql: "SELECT MAX(sortIndex) FROM list") ?? -1) + 1
            try db.execute(sql: "INSERT INTO list (id, name, color, sortIndex, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [id, name, colorHex, next, now, now])
            return Pinboard(id: id, name: name, colorHex: colorHex, sortIndex: next)
        }
    }

    public func updatePinboard(_ pinboard: Pinboard, now: Date = Date()) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE list SET name = ?, color = ?, sortIndex = ?, updatedAt = ? WHERE id = ?",
                           arguments: [pinboard.name, pinboard.colorHex, pinboard.sortIndex, now, pinboard.id])
        }
    }

    /// 删除 Pinboard。原版实测（Docs/归档/调研/08 第 9.1 节）：仍在历史里的条目保留，只是失去归属；
    /// 只存在于这个 Pinboard 的条目（已从历史移出）才随之删除。
    public func deletePinboard(id: String) throws {
        try db.write { db in
            let doomed = try Int64.fetchAll(db, sql: "SELECT id FROM item WHERE listID = ? AND timestamp IS NULL", arguments: [id])
            try Self.deleteRows(db, ids: doomed)
            try db.execute(sql: "UPDATE item SET listID = NULL, displayOrder = 0 WHERE listID = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM list WHERE id = ?", arguments: [id])
        }
        drainPendingAssetDeletes()
    }

    /// 固定只是给同一条记录设置归属，不复制；新固定的排在该 Pinboard 最后。
    public func pin(ids: [Int64], to listID: String, now: Date = Date()) throws {
        try db.write { db in try Self.pin(db, ids: ids, to: listID, now: now) }
    }

    private static func pin(_ db: Database, ids: [Int64], to listID: String, now: Date) throws {
        var next = (try Int.fetchOne(db, sql: "SELECT MAX(displayOrder) FROM item WHERE listID = ?", arguments: [listID]) ?? -1) + 1
        for id in ids {
            try db.execute(sql: "UPDATE item SET listID = ?, displayOrder = ?, updatedAt = ? WHERE id = ?",
                           arguments: [listID, next, now, id])
            next += 1
        }
    }

    /// 在 Pinboard 里拖动排序：把 `ids` 挪到 `target` 前面，`target` 为 nil 表示挪到最后。
    /// 被挪动的几条保持彼此原来的先后；不属于这个 Pinboard 的 id 被忽略。
    public func movePinned(ids: [Int64], in listID: String, before target: Int64?, now: Date = Date()) throws {
        try db.write { db in
            let current = try Int64.fetchAll(db, sql: "SELECT id FROM item WHERE listID = ? ORDER BY displayOrder, id", arguments: [listID])
            let moving = current.filter(Set(ids).contains)
            guard !moving.isEmpty else { return }
            var order = current.filter { !moving.contains($0) }
            // 目标本身也在被挪动的几条里时，落点是它后面第一条没被挪动的。
            var anchor = target
            if let target, moving.contains(target), let position = current.firstIndex(of: target) {
                anchor = current[position...].first { !moving.contains($0) }
            }
            let index = anchor.flatMap { order.firstIndex(of: $0) } ?? order.count
            order.insert(contentsOf: moving, at: index)
            guard order != current else { return }
            for (position, id) in order.enumerated() {
                try db.execute(sql: "UPDATE item SET displayOrder = ?, updatedAt = ? WHERE id = ?", arguments: [position, now, id])
            }
        }
    }

    /// 取消固定。已不在历史里的条目失去归属后无处显示，直接删除。
    public func unpin(ids: [Int64], now: Date = Date()) throws {
        guard !ids.isEmpty else { return }
        try db.write { db in
            let marks = Self.marks(ids.count)
            let doomed = try Int64.fetchAll(db, sql: "SELECT id FROM item WHERE timestamp IS NULL AND id IN (\(marks))",
                                            arguments: StatementArguments(ids))
            try Self.deleteRows(db, ids: doomed)
            var arguments = StatementArguments([now])
            arguments += StatementArguments(ids)
            try db.execute(sql: "UPDATE item SET listID = NULL, displayOrder = 0, updatedAt = ? WHERE id IN (\(marks))", arguments: arguments)
        }
        drainPendingAssetDeletes()
    }

    // MARK: 读取

    public func clips(matching query: ClipQuery = ClipQuery(), limit: Int = 50, offset: Int = 0) throws -> [ClipSummary] {
        var (filter, order, arguments) = Self.matching(query)
        arguments += [limit, offset]
        let sql = """
            SELECT item.*, app.bundleID AS bundleID, app.name AS appName, app.color AS appColor
            FROM item LEFT JOIN app ON app.id = item.appID
            WHERE \(filter)
            ORDER BY \(order) LIMIT ? OFFSET ?
            """
        return try db.read { db in try Row.fetchAll(db, sql: sql, arguments: arguments).map(Self.summary(from:)) }
    }

    /// 符合条件的全部条目 ID，按显示顺序。⌘A 选中整个列表用，不读缩略图等大字段（L33）。
    public func clipIDs(matching query: ClipQuery = ClipQuery()) throws -> [Int64] {
        let (filter, order, arguments) = Self.matching(query)
        let sql = "SELECT item.id FROM item LEFT JOIN app ON app.id = item.appID WHERE \(filter) ORDER BY \(order)"
        return try db.read { db in try Int64.fetchAll(db, sql: sql, arguments: arguments) }
    }

    /// 按 ID 取摘要，顺序与 `ids` 相同；已不存在的跳过。
    public func summaries(ids: [Int64]) throws -> [ClipSummary] {
        var found: [Int64: ClipSummary] = [:]
        try db.read { db in
            // 分批，避免超出 SQLite 的参数个数上限。
            for start in stride(from: 0, to: ids.count, by: 500) {
                let chunk = Array(ids[start..<min(start + 500, ids.count)])
                let rows = try Row.fetchAll(db, sql: """
                    SELECT item.*, app.bundleID AS bundleID, app.name AS appName, app.color AS appColor
                    FROM item LEFT JOIN app ON app.id = item.appID WHERE item.id IN (\(Self.marks(chunk.count)))
                    """, arguments: StatementArguments(chunk))
                for row in rows { let summary = Self.summary(from: row); found[summary.id] = summary }
            }
        }
        return ids.compactMap { found[$0] }
    }

    /// 查询条件拼成的 WHERE 子句、排序和参数。
    private static func matching(_ query: ClipQuery) -> (filter: String, order: String, arguments: StatementArguments) {
        var conditions: [String] = []
        var arguments = StatementArguments()
        let order: String

        switch query.scope {
        case .history:
            conditions.append(query.includePinnedOnly ? "(item.timestamp IS NOT NULL OR item.listID IS NOT NULL)" : "item.timestamp IS NOT NULL")
            // SQLite 里 NULL 最小，降序时只在 Pinboard 里的条目排在最后。
            order = "item.timestamp DESC, item.id DESC"
        case .pinboard(let listID):
            conditions.append("item.listID = ?")
            arguments += [listID]
            order = "item.displayOrder, item.id"
        }
        if !query.kinds.isEmpty {
            conditions.append("item.kind IN (\(Self.marks(query.kinds.count)))")
            arguments += StatementArguments(query.kinds.map(\.rawValue).sorted())
        }
        if !query.bundleIDs.isEmpty {
            conditions.append("app.bundleID IN (\(Self.marks(query.bundleIDs.count)))")
            arguments += StatementArguments(query.bundleIDs.sorted())
        }
        if !query.pinboardIDs.isEmpty {
            conditions.append("item.listID IN (\(Self.marks(query.pinboardIDs.count)))")
            arguments += StatementArguments(query.pinboardIDs.sorted())
        }
        if let since = query.since {
            conditions.append("item.timestamp >= ?")
            arguments += [since]
        }
        if let until = query.until {
            conditions.append("item.timestamp < ?")
            arguments += [until]
        }
        if let title = query.titleContains, !title.isEmpty {
            conditions.append("item.title LIKE ? ESCAPE '\\'")
            arguments += ["%\(Self.escapeLike(title))%"]
        }
        // 多个词之间是“且”的关系；每个词按字面匹配，不解释任何查询语法。
        for term in query.text.split(whereSeparator: \.isWhitespace).map(String.init) {
            if term.count >= 3 {
                conditions.append("item.id IN (SELECT rowid FROM item_fts WHERE item_fts MATCH ?)")
                arguments += ["\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""]
            } else {
                // trigram 索引匹配不了少于 3 个字符的词（如两个汉字），回退到子串匹配。
                conditions.append("item.id IN (SELECT rowid FROM item_fts WHERE content LIKE ? ESCAPE '\\')")
                arguments += ["%\(Self.escapeLike(term))%"]
            }
        }
        return (conditions.joined(separator: " AND "), order, arguments)
    }

    /// 按 uuid 取条目。对外（MCP）只暴露 uuid，不暴露可逐个猜测的自增 id。
    public func summary(uuid: String) throws -> ClipSummary? {
        try db.read { db in
            try Row.fetchOne(db, sql: """
                SELECT item.*, app.bundleID AS bundleID, app.name AS appName, app.color AS appColor
                FROM item LEFT JOIN app ON app.id = item.appID WHERE item.uuid = ?
                """, arguments: [uuid]).map(Self.summary(from:))
        }
    }

    public func summary(id: Int64) throws -> ClipSummary? {
        try db.read { db in try Self.summary(db, id: id) }
    }

    /// 取回完整的剪贴板内容用于回放。外置文件缺失时返回 nil，不回放残缺内容。
    public func snapshot(id: Int64) throws -> ClipSnapshot? {
        guard let row = try db.read({ db in
            try Row.fetchOne(db, sql: """
                SELECT item.uuid, item.createdAt, item.timestamp, item_data.payload, app.bundleID, app.name AS appName
                FROM item JOIN item_data ON item_data.itemID = item.id LEFT JOIN app ON app.id = item.appID
                WHERE item.id = ?
                """, arguments: [id])
        }) else { return nil }

        let stored = try PropertyListDecoder().decode(StoredPayload.self, from: row["payload"])
        var items: [ClipItemSnapshot] = []
        for storedItem in stored.items {
            var reps: [ClipRepresentation] = []
            for rep in storedItem {
                if let data = rep.inline {
                    reps.append(ClipRepresentation(type: rep.type, data: data))
                } else if let name = rep.asset, let data = try? Data(contentsOf: assetDirectory.appendingPathComponent(name)) {
                    reps.append(ClipRepresentation(type: rep.type, data: data))
                } else {
                    return nil
                }
            }
            items.append(ClipItemSnapshot(representations: reps))
        }
        let captured: Date = row["timestamp"] ?? row["createdAt"]
        return ClipSnapshot(id: UUID(uuidString: row["uuid"]) ?? UUID(), items: items, capturedAt: captured,
                            sourceBundleID: row["bundleID"], sourceName: row["appName"])
    }

    /// 各 item 的表示类型（不读外置文件、不解出数据）。拖拽时先声明类型，数据等接收方要时再取（审查 05、08）。
    public func representationTypes(id: Int64) throws -> [[String]]? {
        guard let payload = try db.read({ db in
            try Data.fetchOne(db, sql: "SELECT payload FROM item_data WHERE itemID = ?", arguments: [id])
        }) else { return nil }
        return try PropertyListDecoder().decode(StoredPayload.self, from: payload).items.map { $0.map(\.type) }
    }

    /// 历史里出现过的来源应用，供筛选器使用。
    public func sourceApps() throws -> [(bundleID: String, name: String?)] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT app.bundleID, app.name FROM app
                WHERE EXISTS (SELECT 1 FROM item WHERE item.appID = app.id) ORDER BY app.name
                """).map { (bundleID: $0["bundleID"], name: $0["name"]) }
        }
    }

    /// 记下来源应用的标题栏颜色。
    public func setAppColor(bundleID: String, hex: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE app SET color = ? WHERE bundleID = ?", arguments: [hex, bundleID])
        }
    }

    /// 卡片缓存的数据：开头 `richPreviewLimit` 个字符，有图片时写 RTFD，否则写 RTF。和入库时生成的一样。
    public static func richPreviewData(from rich: NSAttributedString) -> Data? { Derived.richPreview(from: rich) }

    /// 记下来源应用的图标，只在还没有时写入。
    public func setAppIconIfMissing(bundleID: String, png: Data) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE app SET icon = ? WHERE bundleID = ? AND icon IS NULL", arguments: [png, bundleID])
        }
    }

    /// 存下的来源应用图标。
    public func appIcon(bundleID: String) throws -> Data? {
        try db.read { db in try Data.fetchOne(db, sql: "SELECT icon FROM app WHERE bundleID = ?", arguments: [bundleID]) }
    }

    // MARK: 自检与恢复

    public func integrityReport() throws -> IntegrityReport {
        var report = try db.read { db in
            var report = IntegrityReport()
            report.itemsWithoutData = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE id NOT IN (SELECT itemID FROM item_data)") ?? 0
            report.dataWithoutItem = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item_data WHERE itemID NOT IN (SELECT id FROM item)") ?? 0
            report.ftsWithoutItem = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item_fts WHERE rowid NOT IN (SELECT id FROM item)") ?? 0
            report.itemsWithoutFTS = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE id NOT IN (SELECT rowid FROM item_fts)") ?? 0
            report.pendingDeletes = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_asset_delete") ?? 0
            return report
        }
        let rows = Set(try db.read { db in try String.fetchAll(db, sql: "SELECT name FROM item_asset") })
        let files = Set((try? FileManager.default.contentsOfDirectory(atPath: assetDirectory.path)) ?? [])
        report.assetRowsWithoutFile = rows.subtracting(files).count
        report.filesWithoutAssetRow = files.subtracting(rows).count
        return report
    }

    /// 启动时收尾：继续上次没删完的外置文件，并清掉崩溃留下的无主文件。
    private func recoverAfterLaunch() throws {
        drainPendingAssetDeletes()
        let rows = Set(try db.read { db in try String.fetchAll(db, sql: "SELECT name FROM item_asset") })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: assetDirectory.path)) ?? []
        removeAssetFiles(files.filter { !rows.contains($0) })
    }

    private func drainPendingAssetDeletes() {
        guard let names = try? db.read({ db in try String.fetchAll(db, sql: "SELECT name FROM pending_asset_delete") }), !names.isEmpty else { return }
        for name in names {
            let url = assetDirectory.appendingPathComponent(name)
            // 文件已不存在也算完成；删不掉的留在清单里，下次启动再试。
            if (try? FileManager.default.removeItem(at: url)) != nil || !FileManager.default.fileExists(atPath: url.path) {
                _ = try? db.write { db in try db.execute(sql: "DELETE FROM pending_asset_delete WHERE name = ?", arguments: [name]) }
            }
        }
    }

    private func removeAssetFiles(_ names: [String]) {
        for name in names { try? FileManager.default.removeItem(at: assetDirectory.appendingPathComponent(name)) }
    }

    // MARK: 编码与派生数据

    private struct StoredRepresentation: Codable {
        var type: String
        var inline: Data?
        var asset: String?
    }

    private struct StoredPayload: Codable {
        var items: [[StoredRepresentation]]
    }

    private func encodePayload(of snapshot: ClipSnapshot, assetNames: inout [String]) throws -> Data {
        var stored = StoredPayload(items: [])
        for item in snapshot.items {
            var reps: [StoredRepresentation] = []
            for rep in item.representations {
                if rep.data.count > Self.inlineLimit {
                    let name = UUID().uuidString
                    // 原子写入：先写临时文件再改名，数据库不会引用到半截文件。
                    try rep.data.write(to: assetDirectory.appendingPathComponent(name), options: .atomic)
                    assetNames.append(name)
                    reps.append(StoredRepresentation(type: rep.type, inline: nil, asset: name))
                } else {
                    reps.append(StoredRepresentation(type: rep.type, inline: rep.data, asset: nil))
                }
            }
            stored.items.append(reps)
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(stored)
    }

    private struct Derived {
        var previewText = ""
        var searchText = ""
        var charCount = 0
        var thumbnail: Data?
        var pixelWidth: Int?
        var pixelHeight: Int?
        var fileBytes: Int64?
        var richPreview: Data?
        /// 只有 HTML、没有 RTF/RTFD 的文本条目为 0：卡片缓存要由应用在主线程转换后补写（见 `refreshRich`）。
        var richState = 1

        init(snapshot: ClipSnapshot) {
            switch snapshot.kind {
            case .file:
                let paths = snapshot.fileURLs.map(\.path)
                previewText = paths.joined(separator: "\n")
                searchText = previewText
                // 只算普通文件，目录不计；一个都量不到时为空。
                let sizes = snapshot.fileURLs.compactMap { try? $0.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) }
                    .filter { $0.isRegularFile == true }.compactMap(\.fileSize)
                fileBytes = sizes.isEmpty ? nil : Int64(sizes.reduce(0, +))
                // 单个图片文件在复制时就做缩略图（原版卡片显示文件的缩略图，L112）。这时读文件是用户刚复制的，
                // 不会触发文件夹授权询问；以后文件删了、移走了，缩略图还在。
                if snapshot.fileURLs.count == 1, let url = snapshot.fileURLs.first,
                   let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                   let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                    thumbnail = Self.thumbnail(from: source)
                }
            case .image:
                if let data = snapshot.imageData, let source = CGImageSourceCreateWithData(data as CFData, nil) {
                    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                    pixelWidth = properties?[kCGImagePropertyPixelWidth] as? Int
                    pixelHeight = properties?[kCGImagePropertyPixelHeight] as? Int
                    thumbnail = Self.thumbnail(from: source)
                }
                searchText = snapshot.plainText ?? ""
            case .text, .link, .color, .unknown:
                let text = snapshot.plainText ?? ""
                charCount = text.utf16.count
                // 附件占位符 U+FFFC 不进摘要：单独显示没有意义，和中文一起截断时 CoreText 可能卡住（R05）。原文不动。
                previewText = String(text.replacingOccurrences(of: "\u{FFFC}", with: "").prefix(HistoryStore.previewTextLimit))
                searchText = String(text.prefix(HistoryStore.searchTextLimit))
                if snapshot.kind == .text, let rich = snapshot.items.first.flatMap(RichText.decode) {
                    richPreview = Self.richPreview(from: rich)
                    // 卡片的字符数：有富文本时按富文本的 UTF-16 长度（原版：百度那条 3,220，纯文本是 3,071）。
                    charCount = rich.length
                } else if snapshot.kind == .text, snapshot.items.first?.data(for: ClipType.html) != nil {
                    richState = 0
                }
            }
        }

        /// 卡片用的富文本：只留开头 `richPreviewLimit` 个字符；开头有图片时写成 RTFD，否则写 RTF（`RichText.encodePreview`）。
        static func richPreview(from rich: NSAttributedString) -> Data? {
            guard rich.length > 0 else { return nil }
            let head = rich.attributedSubstring(from: NSRange(location: 0, length: min(rich.length, HistoryStore.richPreviewLimit)))
            return RichText.encodePreview(head)
        }

        /// 先读尺寸再降采样，不把整张大图解码进内存。
        static func thumbnail(from source: CGImageSource) -> Data? {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: HistoryStore.thumbnailMaxPixel,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination) ? output as Data : nil
        }
    }

    private static func searchContent(title: String?, text: String, source: String?, ocr: String? = nil, link: String? = nil) -> String {
        [title, link, text, ocr, source].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// 标题、识别结果或链接标题变化后重建该条目的索引行。正文取自原始内容里的纯文本。
    private static func rebuildSearchContent(_ db: Database, id: Int64) throws {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT item.title, item.kind, item.previewText, item.ocrText, item.linkTitle, item_data.payload, app.name AS appName
            FROM item JOIN item_data ON item_data.itemID = item.id LEFT JOIN app ON app.id = item.appID WHERE item.id = ?
            """, arguments: [id]) else { return }
        var text: String = row["previewText"]
        if let stored = try? PropertyListDecoder().decode(StoredPayload.self, from: row["payload"]) {
            let parts = stored.items.compactMap { item in
                item.first { $0.type == ClipType.plainText }?.inline.flatMap { String(data: $0, encoding: .utf8) }
            }
            if !parts.isEmpty { text = String(parts.joined(separator: "\n").prefix(searchTextLimit)) }
        }
        try db.execute(sql: "DELETE FROM item_fts WHERE rowid = ?", arguments: [id])
        try db.execute(sql: "INSERT INTO item_fts (rowid, content) VALUES (?, ?)",
                       arguments: [id, searchContent(title: row["title"], text: text, source: row["appName"], ocr: row["ocrText"], link: row["linkTitle"])])
    }

    private static func summary(from row: Row) -> ClipSummary {
        ClipSummary(
            id: row["id"], uuid: row["uuid"], kind: ClipKind(rawValue: row["kind"]) ?? .unknown, title: row["title"],
            previewText: row["previewText"], thumbnail: row["thumbnail"], pixelWidth: row["pixelWidth"], pixelHeight: row["pixelHeight"],
            charCount: row["charCount"], byteCount: row["byteCount"], timestamp: row["timestamp"], createdAt: row["createdAt"],
            listID: row["listID"], sourceBundleID: row["bundleID"], sourceName: row["appName"], sourceColorHex: row["appColor"],
            linkTitle: row["linkTitle"], linkImage: LinkImageKind(rawValue: row["linkImageKind"]) ?? .none,
            fileBytes: row["fileBytes"],
            richPreview: row["richPreview"]
        )
    }

    private static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    private static func marks(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }
}
