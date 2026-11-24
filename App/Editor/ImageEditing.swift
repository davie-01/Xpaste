import AppKit
import CoreImage
import UniformTypeIdentifiers
import Vision

/// 图片编辑用到的像素操作。都按像素进行，不带 DPI 信息。
enum ImageEditing {
    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 用 ImageIO 写，图片的色彩配置会一起写进 PNG。
    static func png(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// 旋转后的画布沿用原图的色彩空间和位深，广色域、16 位的图片不被压成 8 位 sRGB（L29）。
    private static func canvas(like image: CGImage, width: Int, height: Int) -> CGContext? {
        let space = image.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let deep = image.bitsPerComponent > 8
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: deep ? 16 : 8, bytesPerRow: 0, space: space,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// 按比例缩小到最长边不超过 `maxPixel`；本来就不大于它时原样返回。
    static func downsampled(_ image: CGImage, maxPixel: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxPixel else { return image }
        let scale = Double(maxPixel) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// 逆时针旋转若干个 90°。
    static func rotated(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let width = turns % 2 == 1 ? image.height : image.width
        let height = turns % 2 == 1 ? image.width : image.height
        guard let context = canvas(like: image, width: width, height: height) else { return nil }
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: CGFloat(turns) * .pi / 2)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
        return context.makeImage()
    }

    /// 抠出前景主体，背景变透明，尺寸不变。没有识别到主体时返回 nil。
    static func liftSubject(from image: CGImage) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: image)
            guard (try? handler.perform([request])) != nil, let result = request.results?.first, !result.allInstances.isEmpty,
                  let buffer = try? result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
            else { return nil }
            let masked = CIImage(cvPixelBuffer: buffer)
            return CIContext().createCGImage(masked, from: masked.extent)
        }.value
    }
}
