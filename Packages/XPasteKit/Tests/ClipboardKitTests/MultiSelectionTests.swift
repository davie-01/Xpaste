import AppKit
import Testing
@testable import ClipboardKit

private func text(_ string: String, rtf: Bool = false) -> ClipSnapshot {
    var reps = [ClipRepresentation(type: ClipType.plainText, data: Data(string.utf8))]
    if rtf { reps.append(ClipRepresentation(type: ClipType.rtf, data: Data("{\\rtf1 x}".utf8))) }
    return ClipSnapshot(items: [ClipItemSnapshot(representations: reps)])
}

private func image(_ seed: UInt8) -> ClipSnapshot {
    ClipSnapshot(items: [ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.png, data: Data([0x89, 0x50, seed]))])])
}

private func files(_ paths: [String]) -> ClipSnapshot {
    ClipSnapshot(items: paths.map { ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.fileURL, data: Data("file://\($0)".utf8))]) })
}

@Suite struct MultiSelectionTests {
    @Test func textsAreJoinedInDisplayOrderWithTrailingNewline() throws {
        let composed = try #require(MultiSelection.compose([text("newest", rtf: true), text("https://example.com/"), text("#3366CC")]))
        #expect(composed.items.count == 1)
        #expect(composed.plainText == "newest\nhttps://example.com/\n#3366CC\n")
        #expect(composed.items[0].representations.map(\.type) == [ClipType.plainText, ClipType.rtf])
        // 测试用的 RTF 与纯文本对不上，以纯文本为准。
        let rtf = try #require(composed.items[0].data(for: ClipType.rtf))
        #expect(NSAttributedString(rtf: rtf, documentAttributes: nil)?.string == "newest\nhttps://example.com/\n#3366CC\n")
    }

    /// Stack 的全部粘贴：每项一行，末尾不带换行（原版视频 00:25）。
    @Test func withoutTrailingNewline() throws {
        let composed = try #require(MultiSelection.compose([text("one", rtf: true), text("two")], trailingNewline: false))
        #expect(composed.plainText == "one\ntwo")
        let rtf = try #require(composed.items[0].data(for: ClipType.rtf))
        #expect(NSAttributedString(rtf: rtf, documentAttributes: nil)?.string == "one\ntwo")
    }

    @Test func formattedTextKeepsItsFormatting() throws {
        let bold = NSAttributedString(string: "bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        let boldRTF = try #require(bold.rtf(from: NSRange(location: 0, length: bold.length), documentAttributes: [:]))
        let formatted = ClipSnapshot(items: [ClipItemSnapshot(representations: [
            ClipRepresentation(type: ClipType.plainText, data: Data("bold".utf8)),
            ClipRepresentation(type: ClipType.rtf, data: boldRTF),
        ])])
        let composed = try #require(MultiSelection.compose([text("plain"), formatted]))
        let rtf = try #require(composed.items[0].data(for: ClipType.rtf))
        let rich = try #require(NSAttributedString(rtf: rtf, documentAttributes: nil))
        #expect(rich.string == "plain\nbold\n")
        let font = rich.attribute(.font, at: 6, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        let plainFont = rich.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(plainFont?.fontDescriptor.symbolicTraits.contains(.bold) != true)
    }

    @Test func anyTextMeansOnlyTextIsWritten() throws {
        // 原版实测：文本 + 图片、文本 + 文件写出的都只有那条文本，末尾不带换行。
        #expect(MultiSelection.compose([text("only"), image(1)])?.plainText == "only")
        let mixed = try #require(MultiSelection.compose([files(["/tmp/a"]), text("one"), image(1), text("two")]))
        #expect(mixed.plainText == "one\ntwo\n" && mixed.items.count == 1 && mixed.fileURLs.isEmpty && mixed.imageData == nil)
    }

    @Test func withoutTextEveryItemIsKeptSeparately() throws {
        let composed = try #require(MultiSelection.compose([image(1), files(["/tmp/a", "/tmp/b"]), image(2)]))
        #expect(composed.items.count == 4)
        #expect(composed.items.map { $0.representations[0].type } == [ClipType.png, ClipType.fileURL, ClipType.fileURL, ClipType.png])
        #expect(composed.fileURLs.map(\.path) == ["/tmp/a", "/tmp/b"])
        #expect(composed.kind == .file)

        let pictures = try #require(MultiSelection.compose([image(1), image(2)]))
        #expect(pictures.items.count == 2 && pictures.kind == .image)
    }

    @Test func singleSelectionIsUntouched() {
        let one = text("alone", rtf: true)
        #expect(MultiSelection.compose([one]) == one)
        #expect(MultiSelection.compose([]) == nil)
    }
}
