import ClipboardKit
import Foundation
import Testing
@testable import PasteCore

private func text(_ string: String, rtf: Data? = nil) -> ClipSnapshot {
    var reps = [ClipRepresentation(type: ClipType.plainText, data: Data(string.utf8))]
    if let rtf { reps.append(ClipRepresentation(type: ClipType.rtf, data: rtf)) }
    return ClipSnapshot(items: [ClipItemSnapshot(representations: reps)])
}

private func tempStore() throws -> (HistoryStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xpaste-edit-\(UUID().uuidString)")
    return (try HistoryStore(directory: directory), directory)
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Suite struct EditTests {
    @Test func editKeepsPositionTimeTitleAndPin() throws {
        let (store, directory) = try tempStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.record(text("first"), now: t0)
        let target = try store.record(text("second"), now: t0 + 60)
        try store.record(text("third"), now: t0 + 120)
        let board = try store.createPinboard(name: "Board", colorHex: "#FF0000")
        try store.pin(ids: [target.id], to: board.id)
        try store.setTitle("named", for: target.id)

        let edited = try #require(try store.replaceContent(of: target.id, with: text("second, edited 第二版"), now: t0 + 600))

        #expect(edited.id == target.id && edited.uuid == target.uuid)
        #expect(edited.timestamp == target.timestamp && edited.title == "named" && edited.listID == board.id)
        #expect(edited.previewText == "second, edited 第二版" && edited.charCount == 18)
        #expect(try store.clips().map(\.previewText) == ["third", "second, edited 第二版", "first"])
        #expect(try store.snapshot(id: target.id)?.plainText == "second, edited 第二版")
        // 搜索跟着新内容走，名称仍然可搜。
        #expect(try store.clips(matching: ClipQuery(text: "第二版")).map(\.id) == [target.id])
        #expect(try store.clips(matching: ClipQuery(text: "named")).map(\.id) == [target.id])
        #expect(try store.clips(matching: ClipQuery(text: "second")).count == 1)
        #expect(try store.integrityReport().isClean)
    }

    @Test func fingerprintFollowsNewContent() throws {
        let (store, directory) = try tempStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try store.record(text("before"), now: t0)
        try store.replaceContent(of: original.id, with: text("after"))

        // 再复制新内容：命中这一条，只是回到最前。
        #expect(try store.record(text("after"), now: t0 + 60).id == original.id)
        // 再复制旧内容：是一条新的。
        #expect(try store.record(text("before"), now: t0 + 120).id != original.id)
        #expect(try store.clips().count == 2)
    }

    @Test func editingIntoExistingContentKeepsBoth() throws {
        let (store, directory) = try tempStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = try store.record(text("same"), now: t0)
        let other = try store.record(text("different"), now: t0 + 60)

        let edited = try #require(try store.replaceContent(of: other.id, with: text("same")))

        #expect(edited.id == other.id)
        #expect(try store.clips().map(\.previewText) == ["same", "same"])
        // 之后再复制，命中原先那条。
        #expect(try store.record(text("same"), now: t0 + 120).id == existing.id)
        #expect(try store.clips().count == 2)
        // 撞过的那条还能继续编辑。
        #expect(try store.replaceContent(of: other.id, with: text("third version"))?.previewText == "third version")
        #expect(try store.integrityReport().isClean)
    }

    @Test func kindAndDerivedStateAreRecomputed() throws {
        let (store, directory) = try tempStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = try store.record(text("https://example.com/a"))
        let job = try #require(try store.nextLinkAwaitingMetadata())
        try store.setLinkMetadata(LinkMetadata(title: "Old Title"), for: job)

        // 改了地址：旧标题作废，重新排队去取。
        var edited = try #require(try store.replaceContent(of: clip.id, with: text("https://example.com/b")))
        #expect(edited.kind == .link && edited.linkTitle == nil)
        #expect(try store.nextLinkAwaitingMetadata()?.url == "https://example.com/b")
        #expect(try store.clips(matching: ClipQuery(text: "Old Title")).isEmpty)

        edited = try #require(try store.replaceContent(of: clip.id, with: text("#12AB34")))
        #expect(edited.kind == .color)
        edited = try #require(try store.replaceContent(of: clip.id, with: text("plain words")))
        #expect(edited.kind == .text)
    }

    @Test func largeRepresentationsAreSwappedOnDisk() throws {
        let (store, directory) = try tempStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let big = Data(repeating: 0x41, count: 300_000)
        let clip = try store.record(text("small", rtf: big))
        let assets = directory.appendingPathComponent("Assets")
        #expect(try FileManager.default.contentsOfDirectory(atPath: assets.path).count == 1)

        try store.replaceContent(of: clip.id, with: text("small edited", rtf: Data(repeating: 0x42, count: 300_000)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: assets.path).count == 1)
        #expect(try store.snapshot(id: clip.id)?.items[0].data(for: ClipType.rtf)?.first == 0x42)

        try store.replaceContent(of: clip.id, with: text("no rtf any more"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: assets.path).isEmpty)
        #expect(try store.integrityReport().isClean)
    }

    @Test func editingMissingItemDoesNothing() throws {
        let (store, directory) = try tempStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try store.replaceContent(of: 999, with: text("x", rtf: Data(repeating: 1, count: 300_000))) == nil)
        #expect(try store.integrityReport().isClean)
    }

    @Test func touchingSeveralKeepsTheirRelativeOrder() throws {
        let (store, directory) = try tempStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ids = try (0..<5).map { try store.record(text("item \($0)"), now: t0 + Double($0)).id }
        // 显示顺序是 4 3 2 1 0；选中其中的 3 和 1 粘贴。
        try store.touch(ids: [ids[3], ids[1]], now: t0 + 100)
        #expect(try store.clips().map(\.previewText) == ["item 3", "item 1", "item 4", "item 2", "item 0"])
    }

    @Test func reorderingInsidePinboard() throws {
        let (store, directory) = try tempStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = try store.createPinboard(name: "Board", colorHex: "#FF0000")
        let ids = try (0..<5).map { try store.record(text("pin \($0)"), now: t0 + Double($0)).id }
        try store.pin(ids: ids, to: board.id)
        let outsider = try store.record(text("not pinned"), now: t0 + 50).id
        func order() throws -> [String] { try store.clips(matching: ClipQuery(scope: .pinboard(board.id))).map(\.previewText) }
        #expect(try order() == ["pin 0", "pin 1", "pin 2", "pin 3", "pin 4"])

        // 把最后一条拖到最前。
        try store.movePinned(ids: [ids[4]], in: board.id, before: ids[0])
        #expect(try order() == ["pin 4", "pin 0", "pin 1", "pin 2", "pin 3"])
        // 把两条（多选）拖到最后，彼此顺序不变；不属于这个 Pinboard 的被忽略。
        try store.movePinned(ids: [ids[1], ids[4], outsider], in: board.id, before: nil)
        #expect(try order() == ["pin 0", "pin 2", "pin 3", "pin 4", "pin 1"])
        // 落点就是被拖的那条自己：位置不变。
        try store.movePinned(ids: [ids[2]], in: board.id, before: ids[2])
        #expect(try order() == ["pin 0", "pin 2", "pin 3", "pin 4", "pin 1"])
        // 拖到中间。
        try store.movePinned(ids: [ids[1]], in: board.id, before: ids[3])
        #expect(try order() == ["pin 0", "pin 2", "pin 1", "pin 3", "pin 4"])
        // 历史里的顺序不受影响。
        #expect(try store.clips().first?.previewText == "not pinned")
    }
}
