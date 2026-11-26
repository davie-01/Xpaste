import AppKit
import SQLite3
import ClipboardKit
import Testing
@testable import PasteCore

/// 每个测试用独立的临时目录和真实数据库文件。
final class TempStore {
    let directory: URL
    var store: HistoryStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("xpaste-tests-\(UUID().uuidString)")
        store = try HistoryStore(directory: directory)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func reopen() throws { store = try HistoryStore(directory: directory) }

    var assetFiles: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Assets").path)) ?? []
    }
}

private func text(_ string: String, source: String? = "com.example.editor") -> ClipSnapshot {
    ClipSnapshot(items: [ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.plainText, data: Data(string.utf8))])],
                 sourceBundleID: source, sourceName: source.map { _ in "Editor" })
}

private func blob(_ type: String, bytes: Int, seed: UInt8) -> ClipSnapshot {
    ClipSnapshot(items: [ClipItemSnapshot(representations: [ClipRepresentation(type: type, data: Data(repeating: seed, count: bytes))])])
}

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

@Suite struct RecordTests {
    /// 并发写入相同内容（审查 03）：全部成功、只有一条记录，外置文件不多不少。
    @Test func concurrentDuplicatesBecomeOneItem() async throws {
        let temp = try TempStore()
        let store = temp.store
        let results = await withTaskGroup(of: Result<Int64, Error>.self) { group in
            for index in 0..<64 {
                // 一半是会写外置文件的大内容，一半是小文本。
                let snapshot = index % 2 == 0 ? blob(ClipType.rtf, bytes: 300 * 1024, seed: 7) : text("same text")
                group.addTask { Result { try store.record(snapshot).id } }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.allSatisfy { if case .success = $0 { true } else { false } })
        #expect(Set(results.compactMap { try? $0.get() }).count == 2)
        #expect(try store.clips().count == 2)
        #expect(temp.assetFiles.count == 1)
        #expect(try store.integrityReport().isClean)
    }

    /// 写入和删除交错（审查 03）：不会因为记录在两步之间被删掉而崩溃；结束后库和外置文件一致。
    @Test func recordAndDeleteInterleaved() async throws {
        let temp = try TempStore()
        let store = temp.store
        for round in 0..<20 {
            let snapshot = blob(ClipType.rtf, bytes: 300 * 1024, seed: UInt8(round))
            let first = try store.record(snapshot)
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<8 { group.addTask { _ = try? store.record(snapshot) } }
                group.addTask { try? store.removeFromHistory(ids: [first.id]) }
            }
        }
        #expect(try store.integrityReport().isClean)
        let referenced = try store.clips(limit: 100).count
        #expect(temp.assetFiles.count == referenced, "文件 \(temp.assetFiles.count) 条目 \(referenced)")
    }

    /// 带 Pinboard 新建（MCP）：并发也只有一条，固定在 Pinboard 里、不进历史。
    @Test func concurrentPinnedCreatesStayConsistent() async throws {
        let temp = try TempStore()
        let store = temp.store
        let board = try store.createPinboard(name: "B", colorHex: "#000000")
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 { group.addTask { _ = try? store.createItem(text("pinned once"), pinTo: board.id) } }
        }
        let pinned = try store.clips(matching: ClipQuery(scope: .pinboard(board.id)), limit: 10)
        #expect(pinned.count == 1)
        #expect(try store.clips().isEmpty)
    }

    @Test func keepsTheFirstStoredAppIcon() throws {
        let temp = try TempStore()
        try temp.store.record(text("from editor"), now: t0)
        #expect(try temp.store.appIcon(bundleID: "com.example.editor") == nil)
        try temp.store.setAppIconIfMissing(bundleID: "com.example.editor", png: Data([1, 2, 3]))
        try temp.store.setAppIconIfMissing(bundleID: "com.example.editor", png: Data([9]))
        #expect(try temp.store.appIcon(bundleID: "com.example.editor") == Data([1, 2, 3]))
    }

    @Test func keepsTheHeadOfRichTextForCards() throws {
        let temp = try TempStore()
        let rich = NSMutableAttributedString(string: "Bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 20)])
        rich.append(NSAttributedString(string: String(repeating: "x", count: 1_000)))
        let rtf = try #require(rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]))
        let formatted = try temp.store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [
            ClipRepresentation(type: ClipType.plainText, data: Data(rich.string.utf8)),
            ClipRepresentation(type: ClipType.rtf, data: rtf),
        ])]), now: t0)
        let head = try #require(formatted.richPreview.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) })
        #expect(head.length == HistoryStore.richPreviewLimit)
        let font = try #require(head.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == 20 && font.fontDescriptor.symbolicTraits.contains(.bold))
        // 只有纯文本的条目没有富文本预览。
        let plain = try temp.store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [
            ClipRepresentation(type: ClipType.plainText, data: Data("plain".utf8)),
        ])]), now: t0)
        #expect(plain.richPreview == nil)
    }

    @Test func fillsRichPreviewForHTMLOnlyText() throws {
        let temp = try TempStore()
        let htmlOnly = try temp.store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [
            ClipRepresentation(type: ClipType.plainText, data: Data("WPS 文字".utf8)),
            ClipRepresentation(type: ClipType.html, data: Data("<p>WPS 文字</p>".utf8)),
        ])]), now: t0)
        // 入库时不转 HTML，没有卡片缓存；字符数按纯文本。
        #expect(htmlOnly.richPreview == nil && htmlOnly.charCount == "WPS 文字".utf16.count)
        let rich = NSAttributedString(string: "WPS 文字", attributes: [.foregroundColor: NSColor.red])
        let data = try #require(HistoryStore.richPreviewData(from: rich))
        #expect(try temp.store.fillRichPreview(data, for: htmlOnly.id))
        let filled = try #require(try temp.store.summary(id: htmlOnly.id))
        #expect(filled.richPreview.flatMap(RichText.decodePreview)?.string == "WPS 文字")
        #expect(filled.charCount == "WPS 文字".utf16.count)
        // 已有缓存的不覆盖；非文本条目不写。
        let other = try #require(HistoryStore.richPreviewData(from: NSAttributedString(string: "别的")))
        #expect(try !temp.store.fillRichPreview(other, for: htmlOnly.id))
        let link = try temp.store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [
            ClipRepresentation(type: ClipType.plainText, data: Data("https://example.com".utf8)),
        ])]), now: t0)
        #expect(try !temp.store.fillRichPreview(other, for: link.id))
    }

    @Test func cardCacheKeepsImagesFromRTFD() throws {
        let temp = try TempStore()
        let image = NSImage(size: NSSize(width: 4, height: 2), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let png = try #require(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) })
        let wrapper = FileWrapper(regularFileWithContents: png)
        wrapper.preferredFilename = "picture.png"
        let rich = NSMutableAttributedString(string: "图前")
        rich.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        rich.append(NSAttributedString(string: "图后"))
        let range = NSRange(location: 0, length: rich.length)
        let rtfd = try #require(rich.rtfd(from: range, documentAttributes: [:]))
        let rtf = try #require(rich.rtf(from: range, documentAttributes: [:]))
        // Safari 同时写 RTF 和 RTFD：卡片缓存按 RTFD 取，图片还在。
        let summary = try temp.store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [
            ClipRepresentation(type: ClipType.plainText, data: Data("图前图后".utf8)),
            ClipRepresentation(type: ClipType.rtf, data: rtf),
            ClipRepresentation(type: ClipType.flatRTFD, data: rtfd),
        ])]), now: t0)
        let head = try #require(summary.richPreview.flatMap(RichText.decodePreview))
        var attachments = 0
        head.enumerateAttribute(.attachment, in: NSRange(location: 0, length: head.length)) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        #expect(attachments == 1)
        #expect(head.string.hasPrefix("图前"))
        // 卡片字符数按富文本的 UTF-16 长度：附件占一个字符（原版如此），纯文本里没有它。
        #expect(summary.charCount == rich.length && summary.charCount == "图前图后".utf16.count + 1)
    }

    @Test func recordsFileSizeAtCopyTimeExcludingDirectories() throws {
        let temp = try TempStore()
        let folder = temp.directory.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = folder.appendingPathComponent("a.bin"), second = folder.appendingPathComponent("b.bin")
        try Data(count: 1_000).write(to: first)
        try Data(count: 234).write(to: second)
        func files(_ urls: [URL]) -> ClipSnapshot {
            ClipSnapshot(items: urls.map { ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.fileURL, data: Data($0.absoluteString.utf8))]) })
        }
        let both = try temp.store.record(files([first, second, folder]), now: t0)
        #expect(both.fileBytes == 1_234)
        // 只有目录时量不到大小；文件删掉之后，记下的大小还在。
        #expect(try temp.store.record(files([folder]), now: t0).fileBytes == nil)
        try FileManager.default.removeItem(at: first)
        #expect(try temp.store.summary(id: both.id)?.fileBytes == 1_234)
    }

    /// L112：单个图片文件复制时就有缩略图；其他文件、多个文件没有。
    @Test func singleImageFileGetsAThumbnail() throws {
        let temp = try TempStore()
        let folder = temp.directory.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let picture = folder.appendingPathComponent("photo.png"), note = folder.appendingPathComponent("note.txt")
        try tinyPNG.write(to: picture)
        try Data("x".utf8).write(to: note)
        func files(_ urls: [URL]) -> ClipSnapshot {
            ClipSnapshot(items: urls.map { ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.fileURL, data: Data($0.absoluteString.utf8))]) })
        }
        #expect(try temp.store.record(files([picture]), now: t0).thumbnail != nil)
        #expect(try temp.store.record(files([note]), now: t0).thumbnail == nil)
        #expect(try temp.store.record(files([picture, note]), now: t0).thumbnail == nil)
    }

    /// 一次复制 1 万个文件，一半已经不在了（N07）：入库耗时、摘要大小、回放时文件数不变。
    @Test func tenThousandFilesAreRecordedWithinBudget() throws {
        let temp = try TempStore()
        let folder = temp.directory.appendingPathComponent("many", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = (0..<10_000).map { folder.appendingPathComponent("file-\($0).txt") }
        for url in urls.prefix(5_000) { try Data("x".utf8).write(to: url) }
        let snapshot = ClipSnapshot(items: urls.map { ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.fileURL, data: Data($0.absoluteString.utf8))]) })
        let start = ContinuousClock.now
        let clip = try temp.store.record(snapshot, now: t0)
        let elapsed = ContinuousClock.now - start
        print("10k files: \(elapsed), preview \(clip.previewText.utf8.count) bytes, size \(clip.fileBytes ?? -1)")
        #expect(elapsed < .seconds(2))
        #expect(clip.fileBytes == 5_000)
        #expect(try temp.store.snapshot(id: clip.id)?.fileURLs.count == 10_000)
        for i in 0..<60 { try temp.store.record(text("other \(i)"), now: t0 + Double(i + 1)) }
        let queryStart = ContinuousClock.now
        for _ in 0..<20 { _ = try temp.store.clips(matching: ClipQuery(), limit: 100) }
        // 摘要里是全部路径（约 1.2 MB），列表每页都会读到它；实测一页 100 条约 1.5 ms。
        let pageTime = (ContinuousClock.now - queryStart) / 20
        print("page of 100 with the 10k-file item: \(pageTime)")
        #expect(pageTime < .milliseconds(50))
        #expect(try temp.store.summary(id: clip.id)?.filePaths.count == 10_000)
    }

    @Test func roundTripsFullSnapshot() throws {
        let temp = try TempStore()
        let original = ClipSnapshot(items: [
            ClipItemSnapshot(representations: [
                ClipRepresentation(type: ClipType.plainText, data: Data("hello".utf8)),
                ClipRepresentation(type: ClipType.rtf, data: Data("{\\rtf1 hello}".utf8)),
            ]),
            ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.plainText, data: Data("second".utf8))]),
        ], sourceBundleID: "com.example.app", sourceName: "Example")

        let summary = try temp.store.record(original, now: t0)
        let loaded = try #require(try temp.store.snapshot(id: summary.id))
        #expect(loaded.items == original.items)
        #expect(loaded.fingerprint == original.fingerprint)
        #expect(loaded.id == original.id)
        #expect(summary.sourceBundleID == "com.example.app")
        #expect(summary.sourceName == "Example")
        #expect(summary.kind == .text)
    }

    @Test func duplicateUpdatesTimestampInsteadOfAddingRow() throws {
        let temp = try TempStore()
        let first = try temp.store.record(text("A"), now: t0)
        try temp.store.record(text("B"), now: t0 + 1)
        let again = try temp.store.record(text("A"), now: t0 + 2)

        #expect(again.id == first.id)
        #expect(again.createdAt == t0)
        #expect(again.timestamp == t0 + 2)
        #expect(try temp.store.clips().map(\.previewText) == ["A", "B"])
    }

    @Test func charCountUsesUTF16Units() throws {
        let temp = try TempStore()
        #expect(try temp.store.record(text("a👍")).charCount == 3)
        #expect(try temp.store.record(text("👨‍👩‍👧‍👦")).charCount == 11)
    }

    @Test func storesSourceAppColor() throws {
        let temp = try TempStore()
        let clip = try temp.store.record(text("colored"), now: t0)
        #expect(clip.sourceColorHex == nil)
        try temp.store.setAppColor(bundleID: "com.example.editor", hex: "#3366CC")
        #expect(try temp.store.summary(id: clip.id)?.sourceColorHex == "#3366CC")
        try temp.reopen()
        #expect(try temp.store.clips().first?.sourceColorHex == "#3366CC")
    }

    @Test func survivesReopen() throws {
        let temp = try TempStore()
        try temp.store.record(text("persisted"), now: t0)
        try temp.reopen()
        #expect(try temp.store.clips().map(\.previewText) == ["persisted"])
    }

    @Test func longTextIsTruncatedForPreviewButKeptInFull() throws {
        let temp = try TempStore()
        let long = String(repeating: "x", count: 5_000) + "needle-at-end"
        let summary = try temp.store.record(text(long))
        #expect(summary.previewText.count == 1_000)
        #expect(summary.charCount == long.utf16.count)
        #expect(try temp.store.snapshot(id: summary.id)?.plainText == long)
        #expect(try temp.store.clips(matching: ClipQuery(text: "needle-at-end")).count == 1)
    }

    /// R05：摘要里去掉附件占位符，原文一字不改。
    @Test func objectReplacementCharactersStayOutOfThePreview() throws {
        let temp = try TempStore()
        let raw = "中文\u{FFFC}\u{FFFC}尾部"
        let summary = try temp.store.record(text(raw))
        #expect(summary.previewText == "中文尾部")
        #expect(try temp.store.snapshot(id: summary.id)?.plainText == raw)
        #expect(try temp.store.clips(matching: ClipQuery(text: "尾部")).count == 1)
    }
}

@Suite struct AssetTests {
    @Test func largeRepresentationsGoToFilesAndAreRemovedOnDelete() throws {
        let temp = try TempStore()
        let big = try temp.store.record(blob(ClipType.rtf, bytes: 300 * 1024, seed: 1))
        let small = try temp.store.record(blob(ClipType.rtf, bytes: 1024, seed: 2))
        #expect(temp.assetFiles.count == 1)
        #expect(try temp.store.snapshot(id: big.id)?.byteCount == 300 * 1024)
        #expect(try temp.store.integrityReport().isClean)

        try temp.store.removeFromHistory(ids: [big.id, small.id])
        #expect(temp.assetFiles.isEmpty)
        #expect(try temp.store.integrityReport().isClean)
    }

    @Test func orphanFilesAreCleanedOnLaunch() throws {
        let temp = try TempStore()
        try temp.store.record(blob(ClipType.rtf, bytes: 300 * 1024, seed: 1))
        let stray = temp.directory.appendingPathComponent("Assets/stray-file")
        try Data("left behind by a crash".utf8).write(to: stray)
        #expect(try temp.store.integrityReport().filesWithoutAssetRow == 1)

        try temp.reopen()
        #expect(!FileManager.default.fileExists(atPath: stray.path))
        #expect(temp.assetFiles.count == 1)
        #expect(try temp.store.integrityReport().isClean)
    }

    @Test func missingAssetMeansNoReplay() throws {
        let temp = try TempStore()
        let big = try temp.store.record(blob(ClipType.rtf, bytes: 300 * 1024, seed: 1))
        try FileManager.default.removeItem(at: temp.directory.appendingPathComponent("Assets/\(temp.assetFiles[0])"))
        #expect(try temp.store.snapshot(id: big.id) == nil)
    }
}

/// 1.0.6 之前的文本条目按新规则重算（v8-rich-refresh，L178、L179）。
@Suite struct RichRefreshMigrationTests {
    /// 把库退回到没有 v8 迁移的样子，并把条目改成旧规则下的状态：没有卡片缓存，字符数是旧值。
    private func rollBack(_ temp: TempStore, oldCharCount: [Int64: Int]) throws {
        var handle: OpaquePointer?
        let path = temp.directory.appendingPathComponent("db.sqlite").path
        #expect(sqlite3_open(path, &handle) == SQLITE_OK)
        var sql = """
            DELETE FROM grdb_migrations WHERE identifier = 'v8-rich-refresh';
            DROP INDEX item_on_rich_pending;
            ALTER TABLE item DROP COLUMN richState;
            UPDATE item SET richPreview = NULL WHERE kind = 'text';
            """
        for (id, count) in oldCharCount { sql += "UPDATE item SET charCount = \(count) WHERE id = \(id);" }
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        try temp.reopen()
    }

    @Test func oldTextItemsAreRecomputedWithTheNewRules() throws {
        let temp = try TempStore()
        let rich = NSMutableAttributedString(string: "网页正文", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
        rich.append(NSAttributedString(string: "\u{FFFC}后面"))
        let rtf = try #require(rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]))
        let web = try temp.store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [
            ClipRepresentation(type: ClipType.plainText, data: Data("网页正文后面".utf8)),
            ClipRepresentation(type: ClipType.rtf, data: rtf),
        ])]), now: t0)
        let wps = try temp.store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [
            ClipRepresentation(type: ClipType.plainText, data: Data("WPS 文字".utf8)),
            ClipRepresentation(type: ClipType.html, data: Data("<p>WPS 文字</p>".utf8)),
        ])]), now: t0.addingTimeInterval(1))
        let plain = try temp.store.record(text("纯文本"), now: t0.addingTimeInterval(2))
        let image = try temp.store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [
            ClipRepresentation(type: ClipType.png, data: Data([0x89, 0x50, 0x4E, 0x47])),
        ])]), now: t0.addingTimeInterval(3))
        let expectedCount = try #require(try temp.store.summary(id: web.id)).charCount
        #expect(expectedCount == RichText.decode(ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.rtf, data: rtf)]))?.length)
        // 新规则入库的条目不排队。
        #expect(try temp.store.nextTextAwaitingRichRefresh() == nil)

        try rollBack(temp, oldCharCount: [web.id: 1])
        #expect(try temp.store.summary(id: web.id)?.richPreview == nil)

        // 从最新的开始：纯文本只标记；WPS 交回 HTML；网页按 RTF 重算缓存和字符数；图片不排队。
        var seen: [Int64] = []
        while let job = try temp.store.nextTextAwaitingRichRefresh() {
            #expect(!seen.contains(job.id))
            seen.append(job.id)
            switch try temp.store.refreshRich(job) {
            case .done(let changed):
                #expect(job.id == plain.id ? !changed : (job.id == web.id && changed))
            case .needsHTML(let html):
                #expect(job.id == wps.id && String(decoding: html, as: UTF8.self) == "<p>WPS 文字</p>")
                let data = try #require(HistoryStore.richPreviewData(from: NSAttributedString(string: "WPS 文字")))
                #expect(try temp.store.finishRichRefresh(job, richPreview: data))
            }
        }
        #expect(seen == [plain.id, wps.id, web.id] && !seen.contains(image.id))
        let webAfter = try #require(try temp.store.summary(id: web.id))
        #expect(webAfter.charCount == expectedCount)
        let head = try #require(webAfter.richPreview.flatMap(RichText.decodePreview))
        #expect((head.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 18)
        let wpsAfter = try #require(try temp.store.summary(id: wps.id))
        #expect(wpsAfter.richPreview.flatMap(RichText.decodePreview)?.string == "WPS 文字")
        #expect(wpsAfter.charCount == "WPS 文字".utf16.count)
        #expect(try temp.store.summary(id: plain.id)?.richPreview == nil)
        // 再打开不会重做。
        try temp.reopen()
        #expect(try temp.store.nextTextAwaitingRichRefresh() == nil)
    }

    @Test func lateResultsForDeletedOrRecopiedItemsAreDropped() throws {
        let temp = try TempStore()
        let wps = try temp.store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [
            ClipRepresentation(type: ClipType.plainText, data: Data("WPS".utf8)),
            ClipRepresentation(type: ClipType.html, data: Data("<p>WPS</p>".utf8)),
        ])]), now: t0)
        let other = try temp.store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [
            ClipRepresentation(type: ClipType.plainText, data: Data("另一条".utf8)),
            ClipRepresentation(type: ClipType.html, data: Data("<p>另一条</p>".utf8)),
        ])]), now: t0.addingTimeInterval(1))
        try rollBack(temp, oldCharCount: [:])
        let data = try #require(HistoryStore.richPreviewData(from: NSAttributedString(string: "WPS")))
        // 转换期间被删：不写、不出错。
        let job = OCRJob(id: wps.id, uuid: wps.uuid)
        #expect(try temp.store.refreshRich(job) == .needsHTML(Data("<p>WPS</p>".utf8)))
        try temp.store.removeFromHistory(ids: [wps.id])
        #expect(try !temp.store.finishRichRefresh(job, richPreview: data))
        // 转换期间已经有了缓存（同样内容再复制、补写过）：不覆盖，但标记已处理。
        let otherJob = OCRJob(id: other.id, uuid: other.uuid)
        #expect(try temp.store.refreshRich(otherJob) == .needsHTML(Data("<p>另一条</p>".utf8)))
        let existing = try #require(HistoryStore.richPreviewData(from: NSAttributedString(string: "已有")))
        #expect(try temp.store.fillRichPreview(existing, for: other.id))
        #expect(try !temp.store.finishRichRefresh(otherJob, richPreview: data))
        #expect(try temp.store.summary(id: other.id)?.richPreview.flatMap(RichText.decodePreview)?.string == "已有")
        #expect(try temp.store.nextTextAwaitingRichRefresh() == nil)
    }
}

/// 更新版本写过的库（N11）：旧版本拒绝打开，不改动库，数据还在。
@Suite struct NewerDatabaseTests {
    @Test func olderBuildRefusesAndLeavesTheDatabaseAlone() throws {
        let temp = try TempStore()
        let clip = try temp.store.record(text("写在新版本里的内容"))
        var handle: OpaquePointer?
        let path = temp.directory.appendingPathComponent("db.sqlite").path
        #expect(sqlite3_open(path, &handle) == SQLITE_OK)
        #expect(sqlite3_exec(handle, "INSERT INTO grdb_migrations (identifier) VALUES ('v99-from-the-future')", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(throws: HistoryStore.NewerDatabaseError.self) { try HistoryStore(directory: temp.directory) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
        // 新版本（这里用去掉那条迁移记录来代替）照常打开，内容都在。
        #expect(sqlite3_open(path, &handle) == SQLITE_OK)
        #expect(sqlite3_exec(handle, "DELETE FROM grdb_migrations WHERE identifier = 'v99-from-the-future'", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        try temp.reopen()
        #expect(try temp.store.clips().map(\.id) == [clip.id])
    }
}

/// 删除后的痕迹（R17）：标记文本存进去、改名、删掉后，数据库文件（含 WAL 和日志）的原始字节里不能再有它。
@Suite struct SecureDeleteTests {
    private func rawBytesContain(_ temp: TempStore, _ marker: String) -> [String] {
        let needles = [Data(marker.utf8), Data(marker.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })]
        let files = (try? FileManager.default.contentsOfDirectory(atPath: temp.directory.path)) ?? []
        return files.filter { name in
            guard let data = try? Data(contentsOf: temp.directory.appendingPathComponent(name)) else { return false }
            return needles.contains { data.range(of: $0) != nil }
        }
    }

    @Test func deletedTextLeavesNoTraceInTheDatabaseFiles() throws {
        let temp = try TempStore()
        let marker = "CANARY-7f3a91c2-唯一标记"
        let keep = try temp.store.record(text("留下的内容 \(String(repeating: "x", count: 3000))"))
        let secret = try temp.store.record(text("前文 \(marker) 后文"))
        try temp.store.setTitle("名称 \(marker)", for: secret.id)
        #expect(!rawBytesContain(temp, marker).isEmpty)
        try temp.store.removeFromHistory(ids: [secret.id])
        #expect(try temp.store.clips(matching: ClipQuery(text: "CANARY")).isEmpty)
        #expect(rawBytesContain(temp, marker) == [])
        try temp.reopen()
        #expect(rawBytesContain(temp, marker) == [])
        #expect(try temp.store.clips().map(\.id) == [keep.id])
    }

    @Test func editedAwayTextLeavesNoTrace() throws {
        let temp = try TempStore()
        let marker = "CANARY-edit-41d7"
        let clip = try temp.store.record(text(String(repeating: "长文 ", count: 5_000) + marker))
        #expect(!rawBytesContain(temp, marker).isEmpty)
        try temp.store.replaceContent(of: clip.id, with: text("改过的内容"))
        #expect(try temp.store.clips(matching: ClipQuery(text: "CANARY")).isEmpty)
        #expect(rawBytesContain(temp, marker) == [])
    }

    /// 长文本占用溢出页，删除后这些页进空闲列表；默认的 FAST 模式不一定清零它们。
    @Test func deletedLongTextLeavesNoTrace() throws {
        let temp = try TempStore()
        let marker = "CANARY-long-5b0e"
        let padding = String(repeating: "填充文字 ", count: 10_000)
        let secret = try temp.store.record(text(padding + marker + padding))
        _ = try temp.store.record(text("留下"))
        #expect(!rawBytesContain(temp, marker).isEmpty)
        try temp.store.removeFromHistory(ids: [secret.id])
        #expect(rawBytesContain(temp, marker) == [])
        try temp.reopen()
        #expect(rawBytesContain(temp, marker) == [])
    }
}

/// 写入各阶段出错（R27）：写外置文件、提交事务、提交后删文件。出错后和重启后都不能有指向缺失文件的条目，删掉的也不能复活。
@Suite struct FaultInjectionTests {
    private func setAssetsWritable(_ temp: TempStore, _ writable: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: writable ? 0o700 : 0o500],
                                              ofItemAtPath: temp.directory.appendingPathComponent("Assets").path)
    }

    /// 另开一个连接在库里建触发器，让下一次往 `item_asset` 插入时报错，模拟事务中途失败。
    private func failNextAssetInsert(_ temp: TempStore) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(temp.directory.appendingPathComponent("db.sqlite").path, &handle) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(handle) }
        let sql = "CREATE TRIGGER inject_failure BEFORE INSERT ON item_asset BEGIN SELECT RAISE(ABORT, 'injected'); END"
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    @Test func failedFileWriteLeavesNoRow() throws {
        let temp = try TempStore()
        try setAssetsWritable(temp, false)
        defer { try? setAssetsWritable(temp, true) }
        #expect(throws: (any Error).self) { try temp.store.record(blob(ClipType.rtf, bytes: 300 * 1024, seed: 1)) }
        #expect(try temp.store.clips().isEmpty)
        #expect(temp.assetFiles.isEmpty)
        try setAssetsWritable(temp, true)
        try temp.reopen()
        #expect(try temp.store.clips().isEmpty)
        #expect(try temp.store.integrityReport().isClean)
    }

    @Test func failedTransactionRemovesWrittenFiles() throws {
        let temp = try TempStore()
        try failNextAssetInsert(temp)
        #expect(throws: (any Error).self) { try temp.store.record(blob(ClipType.rtf, bytes: 300 * 1024, seed: 1)) }
        #expect(try temp.store.clips().isEmpty)
        #expect(temp.assetFiles.isEmpty)
        try temp.reopen()
        #expect(try temp.store.clips().isEmpty)
        #expect(try temp.store.integrityReport().isClean)
    }

    @Test func failedFileRemovalAfterCommitIsRetriedOnLaunch() throws {
        let temp = try TempStore()
        let big = try temp.store.record(blob(ClipType.rtf, bytes: 300 * 1024, seed: 1))
        try setAssetsWritable(temp, false)
        defer { try? setAssetsWritable(temp, true) }
        try temp.store.removeFromHistory(ids: [big.id])
        // 记录已删，文件删不掉时记在待删清单里；重启时仍删不掉，条目也不能回来。
        #expect(try temp.store.clips().isEmpty)
        #expect(temp.assetFiles.count == 1)
        #expect(try temp.store.integrityReport().pendingDeletes == 1)
        try temp.reopen()
        #expect(try temp.store.clips().isEmpty)
        #expect(try temp.store.snapshot(id: big.id) == nil)
        #expect(try temp.store.integrityReport().pendingDeletes == 1)
        try setAssetsWritable(temp, true)
        try temp.reopen()
        #expect(temp.assetFiles.isEmpty)
        #expect(try temp.store.integrityReport().isClean)
    }
}

@Suite struct PinboardTests {
    @Test func pinnedItemShowsInBothViewsWithoutCopy() throws {
        let temp = try TempStore()
        let board = try temp.store.createPinboard(name: "Work", colorHex: "#FFCC00")
        let clip = try temp.store.record(text("pinned"), now: t0)
        try temp.store.record(text("other"), now: t0 + 1)
        try temp.store.pin(ids: [clip.id], to: board.id)

        #expect(try temp.store.clips().map(\.previewText) == ["other", "pinned"])
        let inBoard = try temp.store.clips(matching: ClipQuery(scope: .pinboard(board.id)))
        #expect(inBoard.map(\.id) == [clip.id])
    }

    @Test func removingPinnedItemFromHistoryKeepsItInPinboard() throws {
        let temp = try TempStore()
        let board = try temp.store.createPinboard(name: "Work", colorHex: "#FFCC00")
        let pinned = try temp.store.record(text("pinned"), now: t0)
        let plain = try temp.store.record(text("plain"), now: t0 + 1)
        try temp.store.pin(ids: [pinned.id], to: board.id)

        try temp.store.removeFromHistory(ids: [pinned.id, plain.id])
        #expect(try temp.store.clips().isEmpty)
        #expect(try temp.store.clips(matching: ClipQuery(scope: .pinboard(board.id))).map(\.id) == [pinned.id])
        #expect(try temp.store.summary(id: plain.id) == nil)

        // 再次复制相同内容，它带着归属回到历史。
        let again = try temp.store.record(text("pinned"), now: t0 + 5)
        #expect(again.id == pinned.id)
        #expect(again.listID == board.id)
        #expect(try temp.store.clips().map(\.id) == [pinned.id])
    }

    @Test func deleteFromPinboardRemovesRow() throws {
        let temp = try TempStore()
        let board = try temp.store.createPinboard(name: "Work", colorHex: "#FFCC00")
        let clip = try temp.store.record(text("pinned"), now: t0)
        try temp.store.pin(ids: [clip.id], to: board.id)
        try temp.store.deleteFromPinboard(ids: [clip.id])
        #expect(try temp.store.summary(id: clip.id) == nil)
        #expect(try temp.store.integrityReport().isClean)
    }

    @Test func unpinKeepsHistoryItemsAndDropsPinOnlyOnes() throws {
        let temp = try TempStore()
        let board = try temp.store.createPinboard(name: "Work", colorHex: "#FFCC00")
        let inHistory = try temp.store.record(text("in history"), now: t0)
        let pinOnly = try temp.store.record(text("pin only"), now: t0 + 1)
        try temp.store.pin(ids: [inHistory.id, pinOnly.id], to: board.id)
        try temp.store.removeFromHistory(ids: [pinOnly.id])

        try temp.store.unpin(ids: [inHistory.id, pinOnly.id])
        #expect(try temp.store.summary(id: inHistory.id)?.listID == nil)
        #expect(try temp.store.summary(id: pinOnly.id) == nil)
        #expect(try temp.store.integrityReport().isClean)
    }

    @Test func deletingPinboardKeepsHistoryItemsAndDropsPinOnlyOnes() throws {
        let temp = try TempStore()
        let board = try temp.store.createPinboard(name: "Work", colorHex: "#FFCC00")
        let other = try temp.store.createPinboard(name: "Other", colorHex: "#00CCFF")
        let inHistory = try temp.store.record(text("pinned, still in history"), now: t0)
        let pinOnly = try temp.store.record(text("pinned, removed from history"), now: t0 + 1)
        let elsewhere = try temp.store.record(text("in another board"), now: t0 + 2)
        try temp.store.pin(ids: [inHistory.id, pinOnly.id], to: board.id)
        try temp.store.pin(ids: [elsewhere.id], to: other.id)
        try temp.store.removeFromHistory(ids: [pinOnly.id])

        try temp.store.deletePinboard(id: board.id)
        #expect(try temp.store.pinboards().map(\.id) == [other.id])
        // 仍在历史里的条目保留，只是失去归属。
        #expect(try temp.store.summary(id: inHistory.id)?.listID == nil)
        #expect(try temp.store.clips().map(\.id) == [elsewhere.id, inHistory.id])
        // 只存在于被删 Pinboard 的条目随之删除。
        #expect(try temp.store.summary(id: pinOnly.id) == nil)
        // 其他 Pinboard 不受影响。
        #expect(try temp.store.summary(id: elsewhere.id)?.listID == other.id)
        #expect(try temp.store.integrityReport().isClean)
    }

    @Test func newPinsGoToTheEnd() throws {
        let temp = try TempStore()
        let board = try temp.store.createPinboard(name: "Work", colorHex: "#FFCC00")
        let a = try temp.store.record(text("a"), now: t0)
        let b = try temp.store.record(text("b"), now: t0 + 1)
        try temp.store.pin(ids: [b.id], to: board.id)
        try temp.store.pin(ids: [a.id], to: board.id)
        #expect(try temp.store.clips(matching: ClipQuery(scope: .pinboard(board.id))).map(\.previewText) == ["b", "a"])
    }
}

@Suite struct UndoTests {
    @Test func restoresDeletedItemInPlace() throws {
        let temp = try TempStore()
        let a = try temp.store.record(text("a"), now: t0)
        let b = try temp.store.record(text("b"), now: t0 + 1)
        try temp.store.record(text("c"), now: t0 + 2)
        try temp.store.setTitle("标题 B", for: b.id)

        let saved = try temp.store.restorable(ids: [b.id])
        try temp.store.removeFromHistory(ids: [b.id])
        #expect(try temp.store.clips().map(\.previewText) == ["c", "a"])

        let restored = try temp.store.restore(saved)
        let clips = try temp.store.clips()
        #expect(clips.map(\.previewText) == ["c", "b", "a"])
        #expect(clips[1].title == "标题 B")
        #expect(clips[1].timestamp == t0 + 1)
        #expect(clips[1].id == restored[0])
        #expect(try temp.store.clips(matching: ClipQuery(text: "标题")).count == 1)
        #expect(try temp.store.integrityReport().isClean)
        _ = a
    }

    @Test func restoresPinnedItemRemovedFromHistoryAndFromPinboard() throws {
        let temp = try TempStore()
        let board = try temp.store.createPinboard(name: "Work", colorHex: "#FFCC00")
        let clip = try temp.store.record(text("pinned"), now: t0)
        try temp.store.pin(ids: [clip.id], to: board.id)

        // 从历史移出后撤销：回到历史，仍在 Pinboard。
        var saved = try temp.store.restorable(ids: [clip.id])
        try temp.store.removeFromHistory(ids: [clip.id])
        try temp.store.restore(saved)
        #expect(try temp.store.clips().count == 1)
        #expect(try temp.store.clips(matching: ClipQuery(scope: .pinboard(board.id))).count == 1)

        // 从 Pinboard 删除后撤销：归属也恢复。
        saved = try temp.store.restorable(ids: [clip.id])
        try temp.store.deleteFromPinboard(ids: [clip.id])
        #expect(try temp.store.clips().isEmpty)
        try temp.store.restore(saved)
        #expect(try temp.store.clips(matching: ClipQuery(scope: .pinboard(board.id))).map(\.previewText) == ["pinned"])

        // 条目被删后其 Pinboard 也被删了：撤销只恢复到历史，不再带归属。
        saved = try temp.store.restorable(ids: try temp.store.clips().map(\.id))
        try temp.store.removeFromHistory(ids: try temp.store.clips().map(\.id))
        try temp.store.deletePinboard(id: board.id)
        try temp.store.restore(saved)
        #expect(try temp.store.clips().count == 1)
        #expect(try temp.store.clips().first?.listID == nil)
        #expect(try temp.store.integrityReport().isClean)
    }

    @Test func restoresExternalAssets() throws {
        let temp = try TempStore()
        let big = try temp.store.record(blob(ClipType.rtf, bytes: 300 * 1024, seed: 7), now: t0)
        let saved = try temp.store.restorable(ids: [big.id])
        try temp.store.removeFromHistory(ids: [big.id])
        #expect(temp.assetFiles.isEmpty)
        let id = try temp.store.restore(saved)[0]
        #expect(try temp.store.snapshot(id: id)?.byteCount == 300 * 1024)
        #expect(try temp.store.integrityReport().isClean)
    }
}

/// 撤销恢复整批提交、合并规则（审查 04）。
@Suite struct UndoAtomicityTests {
    @Test func failedRestoreLeavesNothingBehind() throws {
        let temp = try TempStore()
        let ids = try (0..<3).map { try temp.store.record(blob(ClipType.rtf, bytes: 300 * 1024, seed: UInt8($0)), now: t0 + Double($0)).id }
        let saved = try temp.store.restorable(ids: ids)
        try temp.store.removeFromHistory(ids: ids)
        temp.store.debugFailRestoreAt = 1
        #expect(throws: (any Error).self) { try temp.store.restore(saved) }
        // 第二条失败：第一条也没留下，这次写出的外置文件都回收了。
        #expect(try temp.store.clips().isEmpty)
        #expect(temp.assetFiles.isEmpty)
        // 同一份撤销数据可以再试。
        temp.store.debugFailRestoreAt = nil
        #expect(try temp.store.restore(saved).count == 3)
        #expect(try temp.store.clips().count == 3)
        #expect(temp.assetFiles.count == 3)
        #expect(try temp.store.integrityReport().isClean)
    }

    @Test func restoreMergesWithContentCopiedAgain() throws {
        let temp = try TempStore()
        let board = try temp.store.createPinboard(name: "Work", colorHex: "#FFCC00")
        let old = try temp.store.record(text("same"), now: t0)
        try temp.store.setTitle("旧名称", for: old.id)
        try temp.store.pin(ids: [old.id], to: board.id)
        let saved = try temp.store.restorable(ids: [old.id])
        try temp.store.deleteFromPinboard(ids: [old.id])
        // 删除后又复制了一次相同内容。
        let again = try temp.store.record(text("same"), now: t0 + 100)
        let restored = try temp.store.restore(saved)
        #expect(restored == [again.id])
        let clip = try #require(try temp.store.summary(id: again.id))
        #expect(clip.timestamp == t0 + 100)      // 保留较新的时间
        #expect(clip.title == "旧名称")            // 现在这条没有名称，用删除前的
        #expect(clip.listID == board.id)         // 现在这条没有归属，用删除前的
        #expect(try temp.store.clips().count == 1)
        #expect(try temp.store.integrityReport().isClean)
    }
}

@Suite struct RetentionTests {
    @Test func eraseHistoryKeepsPinnedItems() throws {
        let temp = try TempStore()
        let board = try temp.store.createPinboard(name: "Work", colorHex: "#FFCC00")
        let pinned = try temp.store.record(text("pinned"), now: t0)
        try temp.store.record(text("plain"), now: t0 + 1)
        try temp.store.pin(ids: [pinned.id], to: board.id)

        try temp.store.eraseHistory()
        #expect(try temp.store.clips().isEmpty)
        #expect(try temp.store.clips(matching: ClipQuery(scope: .pinboard(board.id))).map(\.id) == [pinned.id])
        #expect(try temp.store.integrityReport().isClean)
    }

    @Test func retentionOnlyRemovesOldUnpinnedItems() throws {
        let temp = try TempStore()
        let board = try temp.store.createPinboard(name: "Work", colorHex: "#FFCC00")
        let now = t0 + 40 * 86_400
        let oldPinned = try temp.store.record(text("old pinned"), now: t0)
        let old = try temp.store.record(text("old"), now: t0 + 1)
        let recent = try temp.store.record(text("recent"), now: now - 3_600)
        try temp.store.pin(ids: [oldPinned.id], to: board.id)

        try temp.store.applyRetention(.forever, now: now)
        #expect(try temp.store.clips().count == 3)

        try temp.store.applyRetention(.month, now: now)
        #expect(try temp.store.clips().map(\.id) == [recent.id])
        #expect(try temp.store.summary(id: old.id) == nil)
        #expect(try temp.store.summary(id: oldPinned.id)?.timestamp == nil)
        #expect(try temp.store.clips(matching: ClipQuery(scope: .pinboard(board.id))).map(\.id) == [oldPinned.id])
    }

    /// 对应回归项 R01：大量写入并淘汰后不能留下任何孤儿。
    @Test func noOrphansAfterManyInsertsAndEvictions() throws {
        let temp = try TempStore()
        for i in 0..<2_000 {
            // 每 50 条夹一个外置大对象。
            if i % 50 == 0 {
                try temp.store.record(blob(ClipType.rtf, bytes: 300 * 1024, seed: UInt8(i / 50)), now: t0 + Double(i))
            } else {
                try temp.store.record(text("clip number \(i)"), now: t0 + Double(i))
            }
        }
        #expect(temp.assetFiles.count == 40)

        // 只保留最近一天：时间戳按秒递增，2000 条都在同一天内，先全部过期再检查。
        try temp.store.applyRetention(.day, now: t0 + 2_000 + 86_400 - 100)
        let remaining = try temp.store.clips(limit: 5_000)
        #expect(remaining.count == 100)
        #expect(temp.assetFiles.count == 2)
        #expect(try temp.store.integrityReport().isClean)
    }

    /// 大量清理后按需整理，库文件缩回去（L92）；空闲页不多时不整理。旧模式的库第一次整理时转成增量模式。
    @Test func compactsAfterLargeCleanup() throws {
        let temp = try TempStore()
        func dbSize() -> Int {
            (try? FileManager.default.attributesOfItem(atPath: temp.directory.appendingPathComponent("db.sqlite").path)[.size] as? Int) ?? 0
        }
        var ids: [Int64] = []
        for i in 0..<3_000 { ids.append(try temp.store.record(text("bulk \(i) " + String(repeating: "内容", count: 400))).id) }
        #expect(try temp.store.compactIfNeeded() == false)
        let full = dbSize()
        try temp.store.removeFromHistory(ids: Array(ids.dropFirst(100)))
        #expect(dbSize() == full)
        #expect(try temp.store.compactIfNeeded())
        let compacted = dbSize()
        print("compact: \(full / 1024) KB -> \(compacted / 1024) KB")
        #expect(compacted < full / 4)
        #expect(try temp.store.compactIfNeeded() == false)
        #expect(try temp.store.clips(limit: 200).count == 100)
        #expect(try temp.store.integrityReport().isClean)
    }

    /// 旧版本建的库（不是增量整理模式）：第一次整理用 VACUUM 缩小并转成增量模式，内容不变（L92）。
    @Test func compactionConvertsOldDatabases() throws {
        let temp = try TempStore()
        let path = temp.directory.appendingPathComponent("db.sqlite").path
        func autoVacuumMode() -> Int32 {
            var handle: OpaquePointer?
            defer { sqlite3_close(handle) }
            guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            sqlite3_prepare_v2(handle, "PRAGMA auto_vacuum", -1, &statement, nil)
            return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : -1
        }
        var ids: [Int64] = []
        for i in 0..<2_000 { ids.append(try temp.store.record(text("old \(i) " + String(repeating: "内容", count: 400))).id) }
        // 把库改回旧版本的模式（不整理）。
        var handle: OpaquePointer?
        #expect(sqlite3_open(path, &handle) == SQLITE_OK)
        #expect(sqlite3_exec(handle, "PRAGMA auto_vacuum = NONE; VACUUM;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        #expect(autoVacuumMode() == 0)
        try temp.reopen()
        #expect(autoVacuumMode() == 0)
        try temp.store.removeFromHistory(ids: Array(ids.dropFirst(10)))
        #expect(try temp.store.compactIfNeeded())
        #expect(autoVacuumMode() == 2)
        #expect(try temp.store.clips(limit: 50).count == 10)
        #expect(try temp.store.integrityReport().isClean)
    }

    /// 反复增删后库文件不无限增长（R02）。默认 1 万次增删，`XPASTE_CHURN` 可放大。
    @Test func fileSizeStaysBoundedUnderChurn() throws {
        let temp = try TempStore()
        let total = ProcessInfo.processInfo.environment["XPASTE_CHURN"].flatMap(Int.init) ?? 10_000
        let batch = 1_000
        var sizes: [Int] = []
        for round in 0..<(total / batch) {
            var ids: [Int64] = []
            for i in 0..<batch {
                ids.append(try temp.store.record(text("churn \(round)-\(i) " + String(repeating: "内容", count: 50))).id)
            }
            try temp.store.removeFromHistory(ids: ids)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: temp.directory.path)) ?? []
            sizes.append(files.filter { $0.hasPrefix("db.sqlite") }.reduce(0) { sum, name in
                sum + ((try? FileManager.default.attributesOfItem(atPath: temp.directory.appendingPathComponent(name).path)[.size] as? Int) ?? 0)
            })
        }
        print("churn \(total): sizes \(sizes.map { $0 / 1024 }) KB")
        #expect(try temp.store.clips().isEmpty)
        // 删掉的页进空闲列表给后面复用；全文索引里删除记录的合并滞后，剩下的增长是对数式的。
        // 实测 10 万次：第一轮后 1.8 MB，最终 2.9 MB，最后 3 万次只涨 4 KB。
        #expect(sizes.count >= 3 && sizes.last! <= sizes[0] * 2)
        #expect(try temp.store.integrityReport().isClean)
    }
}

@Suite struct SearchTests {
    @Test func idsOfTheWholeListFollowDisplayOrder() throws {
        let temp = try TempStore()
        for index in 0..<120 { try temp.store.record(text("all-\(index)"), now: t0.addingTimeInterval(Double(index))) }
        try temp.store.record(text("other"), now: t0.addingTimeInterval(500))
        let query = ClipQuery(text: "all-")
        let ids = try temp.store.clipIDs(matching: query)
        #expect(ids.count == 120)
        #expect(ids == (try temp.store.clips(matching: query, limit: 200)).map(\.id))
        let picked = [ids[100], ids[3], ids[57]]
        #expect(try temp.store.summaries(ids: picked + [999_999]).map(\.id) == picked)
    }

    private func seeded() throws -> TempStore {
        let temp = try TempStore()
        let contents = [
            "季度会议纪要 2026", "中文", "hello world", "100% sure", "snake_case_name", "say \"quoted\" text",
            "key: value", "C:\\path\\file", "emoji 🎉 party", "HELLO upper",
        ]
        for (i, content) in contents.enumerated() { try temp.store.record(text(content), now: t0 + Double(i)) }
        return temp
    }

    private func find(_ temp: TempStore, _ query: String) throws -> [String] {
        try temp.store.clips(matching: ClipQuery(text: query)).map(\.previewText).sorted()
    }

    @Test func chineseSubstringsIncludingShortOnes() throws {
        let temp = try seeded()
        #expect(try find(temp, "会议纪要") == ["季度会议纪要 2026"])
        #expect(try find(temp, "中文") == ["中文"])
        #expect(try find(temp, "议") == ["季度会议纪要 2026"])
    }

    @Test func specialCharactersAreLiteral() throws {
        let temp = try seeded()
        #expect(try find(temp, "100%") == ["100% sure"])
        #expect(try find(temp, "%") == ["100% sure"])
        #expect(try find(temp, "_") == ["snake_case_name"])
        #expect(try find(temp, "snake_case") == ["snake_case_name"])
        #expect(try find(temp, "\"quoted\"") == ["say \"quoted\" text"])
        #expect(try find(temp, "key:") == ["key: value"])
        #expect(try find(temp, "C:\\path") == ["C:\\path\\file"])
        #expect(try find(temp, "\\") == ["C:\\path\\file"])
        #expect(try find(temp, "🎉") == ["emoji 🎉 party"])
        #expect(try find(temp, "AND OR NOT *").isEmpty)
    }

    @Test func caseInsensitiveAndMultipleTerms() throws {
        let temp = try seeded()
        #expect(try find(temp, "hello") == ["HELLO upper", "hello world"])
        #expect(try find(temp, "hello world") == ["hello world"])
        #expect(try find(temp, "world hello") == ["hello world"])
        #expect(try find(temp, "   ").count == 10)
    }

    @Test func matchesSourceAppAndTitle() throws {
        let temp = try TempStore()
        let clip = try temp.store.record(text("plain body", source: "com.example.mail"), now: t0)
        #expect(try temp.store.clips(matching: ClipQuery(text: "Editor")).count == 1)

        try temp.store.setTitle("发票模板", for: clip.id)
        #expect(try temp.store.clips(matching: ClipQuery(text: "发票")).count == 1)
        #expect(try temp.store.clips(matching: ClipQuery(text: "plain")).count == 1)
        #expect(try temp.store.integrityReport().isClean)
    }

    @Test func structuredFilters() throws {
        let temp = try TempStore()
        try temp.store.record(text("note", source: "com.example.a"), now: t0)
        try temp.store.record(text("https://example.com/x", source: "com.example.b"), now: t0 + 10)
        try temp.store.record(text("#FF5500", source: "com.example.b"), now: t0 + 20)

        var query = ClipQuery()
        query.kinds = [.link, .color]
        #expect(try temp.store.clips(matching: query).map(\.kind) == [.color, .link])

        query = ClipQuery()
        query.bundleIDs = ["com.example.a"]
        #expect(try temp.store.clips(matching: query).map(\.previewText) == ["note"])

        query = ClipQuery()
        query.since = t0 + 5
        query.until = t0 + 15
        #expect(try temp.store.clips(matching: query).map(\.kind) == [.link])

        #expect(try temp.store.sourceApps().map(\.bundleID) == ["com.example.a", "com.example.b"])
    }

    @Test func paging() throws {
        let temp = try TempStore()
        for i in 0..<120 { try temp.store.record(text("item \(i)"), now: t0 + Double(i)) }
        let first = try temp.store.clips(limit: 50, offset: 0)
        let second = try temp.store.clips(limit: 50, offset: 50)
        #expect(first.first?.previewText == "item 119")
        #expect(second.first?.previewText == "item 69")
        #expect(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
    }
}

@Suite struct ImageTests {
    @Test func imageGetsThumbnailAndPixelSize() throws {
        let png = tinyPNG
        let temp = try TempStore()
        let summary = try temp.store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [
            ClipRepresentation(type: ClipType.png, data: png),
        ])]))
        #expect(summary.kind == .image)
        #expect(summary.pixelWidth == 2)
        #expect(summary.pixelHeight == 1)
        #expect(summary.thumbnail != nil)
    }

    /// 坏图（R26）：声明 6 万 × 6 万但数据残缺的 PNG、只有文件头的垃圾、4000 × 4000 的 TIFF。
    /// 入库要很快完成、不崩溃，原始数据原样保存；解不出来的就没有缩略图。
    @Test func malformedAndHugeImagesAreRecordedQuickly() throws {
        let temp = try TempStore()
        var garbage = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        garbage.append(Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7) }))
        let cases: [(String, String, Data)] = [
            ("huge-png", ClipType.png, pngClaiming(width: 60_000, height: 60_000)),
            ("garbage-png", ClipType.png, garbage),
            ("big-tiff", ClipType.tiff, try bigTIFF(side: 4_000)),
        ]
        for (name, type, data) in cases {
            let start = ContinuousClock.now
            let summary = try temp.store.record(ClipSnapshot(items: [ClipItemSnapshot(representations: [ClipRepresentation(type: type, data: data)])]))
            let elapsed = ContinuousClock.now - start
            print("\(name): \(data.count) bytes, \(elapsed), thumbnail \(summary.thumbnail?.count ?? 0) bytes, \(summary.pixelWidth ?? 0)×\(summary.pixelHeight ?? 0)")
            #expect(elapsed < .seconds(2), "\(name)")
            #expect(try temp.store.snapshot(id: summary.id)?.items.first?.data(for: type) == data, "\(name)")
        }
        #expect(try temp.store.integrityReport().isClean)
    }
}

/// 文件头声明了尺寸、像素数据只有一点点的 PNG。
private func pngClaiming(width: UInt32, height: UInt32) -> Data {
    func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
    func be(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
    func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let typed = Array(type.utf8) + body
        return be(UInt32(body.count)) + typed + be(crc32(typed))
    }
    let header = be(width) + be(height) + [8, 2, 0, 0, 0]
    // 一小段合法的 zlib 数据（空的存储块），远不够填满声明的像素。
    let idat: [UInt8] = [0x78, 0x01, 0x01, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x01]
    return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", header) + chunk("IDAT", idat) + chunk("IEND", []))
}

private func bigTIFF(side: Int) throws -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return try #require(rep.tiffRepresentation)
}

/// 2×1 的最小 PNG；后面追加几个字节不影响解码，用来造出内容不同的图片。
private let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAEElEQVR4nGP4z8DwHwQZYAwAR8oH+Rq28akAAAAASUVORK5CYII=")!

private func image(_ seed: Int) -> ClipSnapshot {
    ClipSnapshot(items: [ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.png, data: tinyPNG + Data("\(seed)".utf8))])])
}

@Suite struct OCRTests {
    @Test func recognizedTextBecomesSearchable() throws {
        let temp = try TempStore()
        let id = try temp.store.record(image(1)).id
        try temp.store.record(text("不相关的文本"))
        #expect(try temp.store.clips(matching: ClipQuery(text: "INV-2026")).isEmpty)

        let job = try #require(try temp.store.nextImageAwaitingOCR())
        #expect(job.id == id)
        #expect(try temp.store.setOCRResult("发票编号 INV-2026\n合计 128.00", for: job))
        #expect(try temp.store.clips(matching: ClipQuery(text: "INV-2026")).map(\.id) == [id])
        #expect(try temp.store.clips(matching: ClipQuery(text: "发票")).map(\.id) == [id])
        #expect(try temp.store.nextImageAwaitingOCR() == nil)
        #expect(try temp.store.integrityReport().isClean)
    }

    @Test func renamingKeepsRecognizedTextInIndex() throws {
        let temp = try TempStore()
        let id = try temp.store.record(image(1)).id
        try temp.store.setOCRResult("quarterly report", for: try #require(try temp.store.nextImageAwaitingOCR()))
        try temp.store.setTitle("截图", for: id)
        #expect(try temp.store.clips(matching: ClipQuery(text: "quarterly")).map(\.id) == [id])
        #expect(try temp.store.clips(matching: ClipQuery(text: "截图")).map(\.id) == [id])
    }

    // R22：识别还没完成条目就被删了，迟到的结果不能写回。
    @Test func lateResultForDeletedItemIsDropped() throws {
        let temp = try TempStore()
        let id = try temp.store.record(image(1)).id
        let job = try #require(try temp.store.nextImageAwaitingOCR())
        try temp.store.removeFromHistory(ids: [id])

        #expect(try temp.store.setOCRResult("secret text", for: job) == false)
        #expect(try temp.store.clips(matching: ClipQuery(text: "secret")).isEmpty)
        #expect(try temp.store.integrityReport().isClean)
    }

    // 识别语言改了以后重新排队：旧文字在新结果写入前仍可搜，失败过的也重试。
    @Test func requeueKeepsOldTextUntilReplaced() throws {
        let temp = try TempStore()
        let id = try temp.store.record(image(1)).id
        try temp.store.record(image(2))
        try temp.store.setOCRResult("old words", for: try #require(try temp.store.nextImageAwaitingOCR()))
        try temp.store.setOCRResult(nil, for: try #require(try temp.store.nextImageAwaitingOCR()))
        #expect(try temp.store.requeueTextRecognition() == 2)
        #expect(try temp.store.clips(matching: ClipQuery(text: "old words")).count == 1)
        var jobs: [OCRJob] = []
        while let job = try temp.store.nextImageAwaitingOCR() {
            jobs.append(job)
            try temp.store.setOCRResult(job.id == id ? "new words" : "second", for: job)
        }
        #expect(jobs.count == 2)
        #expect(try temp.store.clips(matching: ClipQuery(text: "old words")).isEmpty)
        #expect(try temp.store.clips(matching: ClipQuery(text: "new words")).map(\.id) == [id])
        #expect(try temp.store.requeueTextRecognition() == 2)
        #expect(try temp.store.integrityReport().isClean)
    }

    @Test func failedRecognitionIsNotRetried() throws {
        let temp = try TempStore()
        try temp.store.record(image(1))
        try temp.store.setOCRResult(nil, for: try #require(try temp.store.nextImageAwaitingOCR()))
        #expect(try temp.store.nextImageAwaitingOCR() == nil)
    }

    @Test func onlyImagesAreQueuedNewestFirst() throws {
        let temp = try TempStore()
        try temp.store.record(text("文本不需要识别"))
        let first = try temp.store.record(image(1), now: t0).id
        let second = try temp.store.record(image(2), now: t0 + 1).id
        #expect(try temp.store.nextImageAwaitingOCR()?.id == second)
        try temp.store.setOCRResult("", for: try #require(try temp.store.nextImageAwaitingOCR()))
        #expect(try temp.store.nextImageAwaitingOCR()?.id == first)
    }
}

/// 可以从外面控制什么时候“识别完成”的假识别器，并记录同时在跑的数量。
private actor FakeRecognizer {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var started = 0
    private(set) var running = 0
    private(set) var maxRunning = 0

    func recognize(_ data: Data) async -> String {
        started += 1
        running += 1
        maxRunning = max(maxRunning, running)
        await withCheckedContinuation { waiting.append($0) }
        running -= 1
        return "recognized \(data.count)"
    }

    /// 放行一张；还没有任务在等就先等它开始。
    func finishOne() async {
        while waiting.isEmpty { await Task.yield() }
        waiting.removeFirst().resume()
    }
}

@Suite struct OCRIndexerTests {
    @Test func processesBacklogOneAtATime() async throws {
        let temp = try TempStore()
        for i in 0..<3 { try temp.store.record(image(i), now: t0 + Double(i)) }
        let fake = FakeRecognizer()
        let indexer = OCRIndexer(store: temp.store) { await fake.recognize($0) }

        await indexer.kick()
        await indexer.kick()
        for _ in 0..<3 { await fake.finishOne() }
        await indexer.waitUntilIdle()

        #expect(await fake.started == 3)
        #expect(await fake.maxRunning == 1)
        #expect(try temp.store.nextImageAwaitingOCR() == nil)
        #expect(try temp.store.clips(matching: ClipQuery(text: "recognized")).count == 3)
    }

    @Test func itemDeletedDuringRecognitionStaysDeleted() async throws {
        let temp = try TempStore()
        let id = try temp.store.record(image(1)).id
        let fake = FakeRecognizer()
        let indexer = OCRIndexer(store: temp.store) { await fake.recognize($0) }

        await indexer.kick()
        while await fake.started == 0 { await Task.yield() }
        try temp.store.removeFromHistory(ids: [id])
        await fake.finishOne()
        await indexer.waitUntilIdle()

        #expect(try temp.store.clips().isEmpty)
        #expect(try temp.store.clips(matching: ClipQuery(text: "recognized")).isEmpty)
        #expect(try temp.store.integrityReport().isClean)
    }

    @Test func cancelledRecognitionIsRedoneLater() async throws {
        let temp = try TempStore()
        try temp.store.record(image(1))
        let fake = FakeRecognizer()
        let indexer = OCRIndexer(store: temp.store) { await fake.recognize($0) }

        await indexer.kick()
        while await fake.started == 0 { await Task.yield() }
        await indexer.cancel()
        await fake.finishOne()
        await indexer.waitUntilIdle()
        #expect(try temp.store.nextImageAwaitingOCR() != nil)

        await indexer.kick()
        await fake.finishOne()
        await indexer.waitUntilIdle()
        #expect(try temp.store.nextImageAwaitingOCR() == nil)
    }

    @Test func recognizerErrorMarksItemFailedAndMovesOn() async throws {
        struct Boom: Error {}
        let temp = try TempStore()
        for i in 0..<2 { try temp.store.record(image(i), now: t0 + Double(i)) }
        let indexer = OCRIndexer(store: temp.store) { _ in throw Boom() }
        await indexer.kick()
        await indexer.waitUntilIdle()
        #expect(try temp.store.nextImageAwaitingOCR() == nil)
    }
}

@Suite struct PerformanceTests {
    /// 1 万条历史下，首屏查询和搜索的耗时。阈值留了余量，防止退化成全表加载。
    @Test func queriesStayFastWithTenThousandItems() throws {
        let temp = try TempStore()
        let words = ["会议纪要", "invoice", "季度报告", "password reset", "设计评审", "release notes", "购物清单", "meeting"]
        for i in 0..<10_000 {
            let body = "\(words[i % words.count]) 第 \(i) 条 " + String(repeating: "lorem ipsum 填充内容 ", count: 20)
            // 每 20 条里有一张带识别文字的图片，索引比纯文本时更大。
            if i % 20 == 0 {
                try temp.store.record(image(i), now: t0 + Double(i))
                try temp.store.setOCRResult("截图 " + body + String(repeating: "screenshot text 识别出的文字 ", count: 20), for: try #require(try temp.store.nextImageAwaitingOCR()))
            } else {
                try temp.store.record(text(body), now: t0 + Double(i))
            }
        }

        // N06：超长单行 JSON 和百万行 TSV 混在里面。
        let json = "{" + (0..<40_000).map { "\"key\($0)\":\"值 \($0)\"" }.joined(separator: ",") + "}"
        let tsv = (0..<1_000_000).map { "\($0)\tname\t数据" }.joined(separator: "\n")
        let bigStart = ContinuousClock.now
        try temp.store.record(text(json), now: t0 + 20_000)
        try temp.store.record(text(tsv), now: t0 + 20_001)
        print("PERF 写入 \(json.utf8.count / 1024) KB 单行 JSON 和 \(tsv.utf8.count / 1024 / 1024) MB TSV: \(ContinuousClock.now - bigStart)")

        func measure(_ label: String, limitMS: Double, _ work: () throws -> Int) rethrows {
            var samples: [Double] = []
            var count = 0
            for _ in 0..<20 {
                let start = ContinuousClock.now
                count = try work()
                let elapsed = ContinuousClock.now - start
                samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1_000)
            }
            samples.sort()
            let p95 = samples[18]
            print("PERF \(label): p50=\(String(format: "%.2f", samples[10]))ms p95=\(String(format: "%.2f", p95))ms rows=\(count)")
            #expect(p95 < limitMS, "\(label) p95 \(p95)ms")
        }

        try measure("首屏 50 条", limitMS: 30) { try temp.store.clips(limit: 50).count }
        try measure("翻到第 100 页", limitMS: 30) { try temp.store.clips(limit: 50, offset: 5_000).count }
        try measure("搜索 会议纪要", limitMS: 100) { try temp.store.clips(matching: ClipQuery(text: "会议纪要"), limit: 50).count }
        try measure("搜索 两个汉字", limitMS: 100) { try temp.store.clips(matching: ClipQuery(text: "评审"), limit: 50).count }
        try measure("搜索 单个汉字", limitMS: 100) { try temp.store.clips(matching: ClipQuery(text: "购"), limit: 50).count }
        try measure("搜索 无结果", limitMS: 100) { try temp.store.clips(matching: ClipQuery(text: "zzzznotfound"), limit: 50).count }
        try measure("搜索 两个词", limitMS: 100) { try temp.store.clips(matching: ClipQuery(text: "release 9999"), limit: 50).count }
        try measure("搜索 两个字母", limitMS: 100) { try temp.store.clips(matching: ClipQuery(text: "ke"), limit: 50).count }
        try measure("搜索 JSON 里的键", limitMS: 100) { try temp.store.clips(matching: ClipQuery(text: "key39"), limit: 50).count }
        try measure("搜索 TSV 里的字", limitMS: 100) { try temp.store.clips(matching: ClipQuery(text: "数"), limit: 50).count }
    }
}
