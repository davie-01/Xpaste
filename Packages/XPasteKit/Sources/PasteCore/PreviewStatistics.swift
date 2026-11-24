import Foundation

/// 文本预览底栏的三项计数。
public struct TextStatistics: Sendable, Equatable {
    /// UTF-16 码元数，与卡片底栏口径一致。
    public let characters: Int
    /// 按空格切分的段数。原版对中文和连字符都不拆词，换行也不算分隔（Docs/归档/调研/08 第 9.11 节）。
    public let words: Int
    public let lines: Int

    public init(_ text: String) {
        characters = text.utf16.count
        words = text.split(separator: " ", omittingEmptySubsequences: true).count
        lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
    }
}

/// 颜色预览底栏的三组数值，按 sRGB 计算。
public struct ColorComponents: Sendable, Equatable {
    /// 0…255
    public let rgb: [Int]
    /// 色相 0…360，饱和度和亮度 0…100
    public let hsl: [Int]
    public let hsb: [Int]

    /// 接受 6 位十六进制，`#` 可有可无。
    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        let r = (value >> 16) & 0xFF, g = (value >> 8) & 0xFF, b = value & 0xFF
        rgb = [r, g, b]

        let (rf, gf, bf) = (Double(r) / 255, Double(g) / 255, Double(b) / 255)
        let high = max(rf, gf, bf), low = min(rf, gf, bf), delta = high - low
        var hue = 0.0
        if delta > 0 {
            switch high {
            case rf: hue = ((gf - bf) / delta).truncatingRemainder(dividingBy: 6)
            case gf: hue = (bf - rf) / delta + 2
            default: hue = (rf - gf) / delta + 4
            }
            hue *= 60
            if hue < 0 { hue += 360 }
        }
        let lightness = (high + low) / 2
        let hslSaturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
        let hsbSaturation = high == 0 ? 0 : delta / high
        func percent(_ value: Double) -> Int { Int((value * 100).rounded()) }
        hsl = [Int(hue.rounded()), percent(hslSaturation), percent(lightness)]
        hsb = [Int(hue.rounded()), percent(hsbSaturation), percent(high)]
    }
}
