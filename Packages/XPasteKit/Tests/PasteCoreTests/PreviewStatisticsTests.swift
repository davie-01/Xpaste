import Testing
@testable import PasteCore

@Suite struct PreviewStatisticsTests {
    private func counts(_ text: String) -> [Int] {
        let stats = TextStatistics(text)
        return [stats.characters, stats.words, stats.lines]
    }

    // 三组样本都来自原版预览底栏的实际显示。
    @Test func textCountsMatchBaselineSamples() {
        #expect(counts("karpathy-skills") == [15, 1, 1])
        #expect(counts("XPQ-M3-B second item with a few words") == [37, 7, 1])
        #expect(counts("XPaste 基准采集用的文本条目，第二行\n第三行") == [25, 2, 2])
    }

    @Test func textCountsEdgeCases() {
        #expect(counts("") == [0, 0, 1])
        #expect(counts("a  b ") == [5, 2, 1])
        #expect(counts("a\r\nb\n") == [5, 1, 3])
        #expect(TextStatistics("a👍").characters == 3)
    }

    @Test func colorComponents() throws {
        let blue = try #require(ColorComponents(hex: "#3366CC"))
        #expect(blue.rgb == [51, 102, 204])
        #expect(blue.hsl == [220, 60, 50])
        #expect(blue.hsb == [220, 75, 80])

        #expect(ColorComponents(hex: "ff5500")?.rgb == [255, 85, 0])
        #expect(ColorComponents(hex: "#000000")?.hsl == [0, 0, 0])
        #expect(ColorComponents(hex: "#FFFFFF")?.hsb == [0, 0, 100])
        #expect(ColorComponents(hex: "#FF0000")?.hsl == [0, 100, 50])
        #expect(ColorComponents(hex: "#FFF") == nil)
        #expect(ColorComponents(hex: "#GGGGGG") == nil)
    }
}
