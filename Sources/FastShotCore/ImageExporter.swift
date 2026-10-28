import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageFormat: String, Codable, CaseIterable, Sendable {
    case png, jpeg

    public var fileExtension: String { self == .png ? "png" : "jpg" }
    public var utType: UTType { self == .png ? .png : .jpeg }
}

public enum ImageExporter {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func bitmapContext(width: Int, height: Int, colorSpace: CGColorSpace?) -> CGContext? {
        let space = colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? sRGB
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Prepares a bitmap context so drawing happens in y-down canvas points.
    static func canvasTransform(_ ctx: CGContext, pixelHeight: Int, scaleX: CGFloat, scaleY: CGFloat) {
        ctx.translateBy(x: 0, y: CGFloat(pixelHeight))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: scaleX, y: scaleY)
        ctx.interpolationQuality = .high
    }

    /// Burns annotations into the capture at its full pixel resolution.
    public static func flatten(background: CGImage, canvasSize: CGSize, annotations: [Annotation]) -> CGImage? {
        guard canvasSize.width > 0, canvasSize.height > 0,
              let ctx = bitmapContext(width: background.width, height: background.height, colorSpace: background.colorSpace) else { return nil }
        canvasTransform(ctx, pixelHeight: background.height,
                        scaleX: CGFloat(background.width) / canvasSize.width, scaleY: CGFloat(background.height) / canvasSize.height)
        AnnotationRenderer.drawImage(background, in: CGRect(origin: .zero, size: canvasSize), ctx: ctx)
        AnnotationRenderer.draw(annotations, in: ctx, background: background, canvasSize: canvasSize)
        return ctx.makeImage()
    }

    /// Annotations alone on a transparent layer, for compositing over video frames.
    public static func overlay(pixelWidth: Int, pixelHeight: Int, canvasSize: CGSize, annotations: [Annotation]) -> CGImage? {
        guard canvasSize.width > 0, canvasSize.height > 0,
              let ctx = bitmapContext(width: pixelWidth, height: pixelHeight, colorSpace: sRGB) else { return nil }
        canvasTransform(ctx, pixelHeight: pixelHeight,
                        scaleX: CGFloat(pixelWidth) / canvasSize.width, scaleY: CGFloat(pixelHeight) / canvasSize.height)
        AnnotationRenderer.draw(annotations, in: ctx, background: nil, canvasSize: canvasSize)
        return ctx.makeImage()
    }

    /// Shrinks an image so its longer side is at most `maxSide` pixels.
    public static func scaled(_ image: CGImage, maxSide: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maxSide else { return image }
        let factor = CGFloat(maxSide) / CGFloat(longest)
        let width = max(1, Int(CGFloat(image.width) * factor)), height = max(1, Int(CGFloat(image.height) * factor))
        guard let ctx = bitmapContext(width: width, height: height, colorSpace: image.colorSpace) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Encodes an image; `pointScale` writes matching DPI so apps paste it at its on-screen size.
    public static func encode(_ image: CGImage, format: ImageFormat, quality: Double = 0.9, pointScale: Double = 1) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else { return nil }
        var properties: [CFString: Any] = [kCGImagePropertyDPIWidth: 72 * pointScale, kCGImagePropertyDPIHeight: 72 * pointScale]
        if format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    public static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Points-per-pixel hint read from an image file's DPI (144 dpi ⇒ 2).
    public static func pointScale(of url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let dpi = properties[kCGImagePropertyDPIWidth] as? Double, dpi > 72 else { return nil }
        return (dpi / 72).rounded()
    }
}
