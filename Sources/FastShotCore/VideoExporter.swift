import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum VideoFormat: String, CaseIterable, Sendable {
    case mp4, mov, gif

    public var fileExtension: String { rawValue }
    public var utType: UTType {
        switch self {
        case .mp4: return .mpeg4Movie
        case .mov: return .quickTimeMovie
        case .gif: return .gif
        }
    }
    var fileType: AVFileType { self == .mov ? .mov : .mp4 }
}

public struct VideoExportRequest: Sendable {
    public var source: URL
    public var canvasSize: CGSize
    public var annotations: [Annotation]
    public var trim: ClosedRange<Double>?
    public var preferHEVC: Bool

    public init(source: URL, canvasSize: CGSize, annotations: [Annotation], trim: ClosedRange<Double>? = nil, preferHEVC: Bool = false) {
        self.source = source
        self.canvasSize = canvasSize
        self.annotations = annotations
        self.trim = trim
        self.preferHEVC = preferHEVC
    }
}

public enum VideoExportError: LocalizedError {
    case cannotCreateSession
    case cannotWriteGIF
    case noFrames

    public var errorDescription: String? {
        switch self {
        case .cannotCreateSession: return "Video dışa aktarma oturumu oluşturulamadı."
        case .cannotWriteGIF: return "GIF dosyası yazılamadı."
        case .noFrames: return "Videodan kare okunamadı."
        }
    }
}

/// Paints the annotations visible at a frame's time over that frame. Overlays
/// without pixelation are cached, because a mark looks the same on every frame
/// it spans; pixelation samples the frame itself and is drawn per frame.
public final class AnnotationFrameRenderer: @unchecked Sendable {
    let canvasSize: CGSize
    let annotations: [Annotation]
    let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var cachedKey: [UUID] = []
    private var cachedSize: CGSize = .zero
    private var cachedOverlay: CIImage?

    public init(canvasSize: CGSize, annotations: [Annotation]) {
        self.canvasSize = canvasSize
        self.annotations = annotations
    }

    public func render(source: CIImage, time: Double) -> CIImage {
        let visible = annotations.filter { $0.isVisible(at: time) }
        guard !visible.isEmpty else { return source }
        let extent = source.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0 else { return source }
        if visible.contains(where: { $0.kind == .pixelate }) {
            guard let frame = context.createCGImage(source, from: extent, format: .RGBA8, colorSpace: ImageExporter.sRGB),
                  let flattened = ImageExporter.flatten(background: frame, canvasSize: canvasSize, annotations: visible) else { return source }
            return CIImage(cgImage: flattened).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        }
        let key = visible.map(\.id)
        lock.lock()
        defer { lock.unlock() }
        if key != cachedKey || cachedSize != extent.size || cachedOverlay == nil {
            guard let overlay = ImageExporter.overlay(pixelWidth: width, pixelHeight: height, canvasSize: canvasSize, annotations: visible) else { return source }
            cachedOverlay = CIImage(cgImage: overlay)
            cachedKey = key
            cachedSize = extent.size
        }
        return cachedOverlay!.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY)).composited(over: source)
    }
}

public enum VideoExporter {
    public static func composition(for asset: AVAsset, renderer: AnnotationFrameRenderer) async throws -> AVVideoComposition {
        try await AVVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { request in
            let source = request.sourceImage
            let output = renderer.render(source: source, time: request.compositionTime.seconds)
            request.finish(with: output.cropped(to: source.extent), context: nil)
        })
    }

    static func timeRange(_ range: ClosedRange<Double>) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                    end: CMTime(seconds: range.upperBound, preferredTimescale: 600))
    }

    /// Writes an MP4/MOV with the annotations burned in. Untouched recordings are
    /// copied, and trims without annotations avoid re-encoding.
    public static func export(_ request: VideoExportRequest, to url: URL, format: VideoFormat,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        if format == .gif {
            try await exportGIF(request, to: url, progress: progress)
            return
        }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: url)
        let asset = AVURLAsset(url: request.source)
        let duration = try await asset.load(.duration).seconds
        let trim = request.trim.flatMap { range -> ClosedRange<Double>? in
            range.lowerBound <= 0.01 && range.upperBound >= duration - 0.01 ? nil : range
        }
        let sameContainer = request.source.pathExtension.lowercased() == format.fileExtension
        if request.annotations.isEmpty, trim == nil, sameContainer {
            try fileManager.copyItem(at: request.source, to: url)
            progress(1)
            return
        }
        let preset: String
        if request.annotations.isEmpty {
            preset = AVAssetExportPresetPassthrough
        } else {
            preset = request.preferHEVC ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw VideoExportError.cannotCreateSession }
        if !request.annotations.isEmpty {
            let renderer = AnnotationFrameRenderer(canvasSize: request.canvasSize, annotations: request.annotations)
            session.videoComposition = try await composition(for: asset, renderer: renderer)
        }
        if let trim { session.timeRange = timeRange(trim) }
        session.shouldOptimizeForNetworkUse = true
        let monitor = Task {
            for await state in session.states(updateInterval: 0.15) {
                if case .exporting(let fraction) = state { progress(fraction.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: url, as: format.fileType)
        progress(1)
    }

    /// Renders an animated GIF of the (trimmed) recording with its annotations.
    public static func exportGIF(_ request: VideoExportRequest, to url: URL, fps: Double = 12, maxWidth: CGFloat = 1000,
                                 progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        let asset = AVURLAsset(url: request.source)
        let duration = try await asset.load(.duration).seconds
        let range = request.trim ?? 0...duration
        let generator = AVAssetImageGenerator(asset: asset)
        if !request.annotations.isEmpty {
            let renderer = AnnotationFrameRenderer(canvasSize: request.canvasSize, annotations: request.annotations)
            generator.videoComposition = try await composition(for: asset, renderer: renderer)
        }
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)
        let count = max(1, Int(((range.upperBound - range.lowerBound) * fps).rounded(.down)))
        let times = (0..<count).map { CMTime(seconds: range.lowerBound + Double($0) / fps, preferredTimescale: 600) }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw VideoExportError.cannotWriteGIF
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps,
                                                               kCGImagePropertyGIFUnclampedDelayTime: 1 / fps]] as CFDictionary
        var written = 0, finished = 0
        for await result in generator.images(for: times) {
            finished += 1
            if case .success(_, let image, _) = result {
                CGImageDestinationAddImage(destination, image, frameProperties)
                written += 1
            }
            progress(Double(finished) / Double(count))
        }
        guard written > 0 else { throw VideoExportError.noFrames }
        guard CGImageDestinationFinalize(destination) else { throw VideoExportError.cannotWriteGIF }
    }

    /// A still of the recording at `time`, used for thumbnails and paused previews.
    public static func frame(of url: URL, at time: Double, maxSide: CGFloat? = nil) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let maxSide { generator.maximumSize = CGSize(width: maxSide, height: maxSide) }
        return try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }
}
