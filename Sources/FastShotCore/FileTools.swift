import AVFoundation
import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Changes a file's content without changing its kind.
public enum FileTool: String, CaseIterable, Sendable {
    case edit, crop, background, compress, metadata, recognizeText, translate, removeAudio, mergePDF
}

/// Does something with files as they are.
public enum FileAction: String, CaseIterable, Sendable {
    case zip, unzip, airDrop, copyToClipboard, copyPath, pin, terminal
}

/// The ⌘ (tools) and ⌃ (actions) wheels' work. Results are written as new files
/// next to the originals; nothing is changed in place.
public enum FileTools {
    // MARK: What applies

    public static func tools(for urls: [URL]) -> [FileTool] {
        let families = Set(urls.map(FileConverter.family(of:)))
        guard families.count == 1, let family = families.first ?? nil else { return [] }
        let single = urls.count == 1
        switch family {
        case .image:
            return single ? [.edit, .crop, .background, .compress, .metadata, .recognizeText, .translate] : [.edit, .background, .compress, .metadata]
        case .video:
            return (single ? [.edit] : []) + [.compress, .removeAudio, .metadata]
        case .audio:
            let rewritable = urls.allSatisfy { ["m4a", "mp4", "aac", "mov", "m4b"].contains($0.pathExtension.lowercased()) }
            return [.compress] + (rewritable ? [.metadata] : [])
        case .pdf:
            return [.compress, .metadata] + (single ? [] : [.mergePDF])
        case .document:
            return []
        }
    }

    public static func actions(for urls: [URL]) -> [FileAction] {
        guard !urls.isEmpty else { return [] }
        let allZip = urls.allSatisfy { $0.pathExtension.lowercased() == "zip" }
        let allImages = urls.count <= 6 && urls.allSatisfy { FileConverter.family(of: $0) == .image }
        var list: [FileAction] = [allZip ? .unzip : .zip, .airDrop, .copyToClipboard, .copyPath]
        if allImages { list.append(.pin) }
        list.append(.terminal)
        return list
    }

    static func output(for url: URL, in folder: URL, suffix: String, ext: String? = nil) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        return FileConverter.uniqueURL(in: folder, base: "\(base) (\(suffix))", ext: ext ?? url.pathExtension.lowercased())
    }

    static func imageSource(_ url: URL) throws -> (CGImageSource, [CFString: Any]) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        return (source, CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:])
    }

    static func write(_ image: CGImage, uti: String, to output: URL, quality: Double, dpi: Any? = nil) throws {
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, uti as CFString, 1, nil) else {
            throw ConversionError.unsupported(output.lastPathComponent)
        }
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let dpi { options[kCGImagePropertyDPIWidth] = dpi; options[kCGImagePropertyDPIHeight] = dpi }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw ConversionError.writeFailed(output.lastPathComponent)
        }
    }

    /// The source's own image type when macOS can write it, PNG otherwise.
    static func writableType(of url: URL) -> (uti: String, ext: String) {
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        if let type = UTType(filenameExtension: url.pathExtension.lowercased()), writable.contains(type.identifier) {
            return (type.identifier, url.pathExtension.lowercased())
        }
        return (UTType.png.identifier, "png")
    }

    // MARK: Compress

    public static func compress(_ url: URL, folder: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        switch FileConverter.family(of: url) {
        case .image:
            return try compressImage(url, folder: folder)
        case .video:
            let output = self.output(for: url, in: folder, suffix: "küçük", ext: "mp4")
            try await FileConverter.export(AVURLAsset(url: url), preset: AVAssetExportPresetHEVC1920x1080, fileType: .mp4, to: output, progress: progress)
            return output
        case .audio:
            let output = self.output(for: url, in: folder, suffix: "küçük", ext: "m4a")
            try await FileConverter.convertAudio(url, to: .m4a, output: output, bitRate: 128_000, progress: progress)
            return output
        case .pdf:
            guard let document = PDFDocument(url: url) else { throw ConversionError.unreadable(url.lastPathComponent) }
            let output = self.output(for: url, in: folder, suffix: "küçük")
            let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
            guard document.write(to: output, withOptions: options) else { throw ConversionError.writeFailed(output.lastPathComponent) }
            return output
        default:
            throw ConversionError.unsupported(url.lastPathComponent)
        }
    }

    /// Lossy formats are re-encoded at a lower quality; lossless ones become JPEG (or HEIC when they have transparency).
    static func compressImage(_ url: URL, folder: URL) throws -> URL {
        let (source, properties) = try imageSource(url)
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0, height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: min(max(width, height, 1), 3840)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ConversionError.unreadable(url.lastPathComponent) }
        let ext = url.pathExtension.lowercased()
        let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        let (uti, outExt, quality): (String, String, Double) = {
            switch ext {
            case "jpg", "jpeg": return (UTType.jpeg.identifier, "jpg", 0.68)
            case "heic", "heif": return (UTType.heic.identifier, "heic", 0.6)
            case "avif": return ("public.avif", "avif", 0.6)
            default: return hasAlpha ? (UTType.heic.identifier, "heic", 0.65) : (UTType.jpeg.identifier, "jpg", 0.75)
            }
        }()
        let output = self.output(for: url, in: folder, suffix: "küçük", ext: outExt)
        try write(hasAlpha && uti == UTType.jpeg.identifier ? (FileConverter.flattened(image) ?? image) : image, uti: uti, to: output, quality: quality,
                  dpi: properties[kCGImagePropertyDPIWidth])
        return output
    }

    // MARK: Metadata

    /// Writes a copy without location, camera and author details. Image pixels keep their orientation.
    public static func stripMetadata(_ url: URL, folder: URL) async throws -> URL {
        switch FileConverter.family(of: url) {
        case .image:
            let (source, properties) = try imageSource(url)
            guard let image = FileConverter.orientedImage(source) else { throw ConversionError.unreadable(url.lastPathComponent) }
            let (uti, ext) = writableType(of: url)
            let output = self.output(for: url, in: folder, suffix: "temiz", ext: ext)
            try write(image, uti: uti, to: output, quality: 0.95, dpi: properties[kCGImagePropertyDPIWidth])
            return output
        case .video, .audio:
            let asset = AVURLAsset(url: url)
            let ext = url.pathExtension.lowercased()
            let fileType: AVFileType = ext == "mov" ? .mov : (ext == "m4a" || ext == "aac" || ext == "m4b") ? .m4a : .mp4
            let output = self.output(for: url, in: folder, suffix: "temiz", ext: fileType == .m4a ? "m4a" : ext == "mov" ? "mov" : "mp4")
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                throw ConversionError.unsupported(url.lastPathComponent)
            }
            session.metadata = []
            session.metadataItemFilter = .forSharing()
            try await session.export(to: output, as: fileType)
            return output
        case .pdf:
            guard let document = PDFDocument(url: url) else { throw ConversionError.unreadable(url.lastPathComponent) }
            document.documentAttributes = [:]
            let output = self.output(for: url, in: folder, suffix: "temiz")
            guard document.write(to: output) else { throw ConversionError.writeFailed(output.lastPathComponent) }
            return output
        default:
            throw ConversionError.unsupported(url.lastPathComponent)
        }
    }

    // MARK: Images

    /// Crops to `rect`, given in image pixels from the top-left corner.
    public static func crop(_ url: URL, to rect: CGRect, folder: URL) throws -> URL {
        let (source, properties) = try imageSource(url)
        guard let image = FileConverter.orientedImage(source) else { throw ConversionError.unreadable(url.lastPathComponent) }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let area = rect.integral.intersection(bounds)
        guard !area.isNull, area.width >= 1, area.height >= 1, let cropped = image.cropping(to: area) else {
            throw ConversionError.unsupported(url.lastPathComponent)
        }
        let (uti, ext) = writableType(of: url)
        let output = self.output(for: url, in: folder, suffix: "kırpılmış", ext: ext)
        try write(cropped, uti: uti, to: output, quality: 0.92, dpi: properties[kCGImagePropertyDPIWidth])
        return output
    }

    /// Puts the image on a soft gradient with padding, rounded corners and a shadow — ready to share.
    public static func addBackground(_ url: URL, folder: URL) throws -> URL {
        let (source, properties) = try imageSource(url)
        guard let image = FileConverter.orientedImage(source) else { throw ConversionError.unreadable(url.lastPathComponent) }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let padding = max(48, (max(w, h) * 0.08).rounded())
        let canvas = CGSize(width: w + padding * 2, height: h + padding * 2)
        guard let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.writeFailed(url.lastPathComponent)
        }
        let colors = [CGColor(srgbRed: 0.42, green: 0.36, blue: 0.98, alpha: 1), CGColor(srgbRed: 0.16, green: 0.62, blue: 1, alpha: 1),
                      CGColor(srgbRed: 0.36, green: 0.86, blue: 0.86, alpha: 1)]
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0), options: [])
        let frame = CGRect(x: padding, y: padding, width: w, height: h)
        let radius = max(8, min(w, h) * 0.02)
        let shape = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -padding * 0.18), blur: padding * 0.55, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(shape)
        ctx.setFillColor(.white)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(image, in: frame)
        guard let result = ctx.makeImage() else { throw ConversionError.writeFailed(url.lastPathComponent) }
        let output = self.output(for: url, in: folder, suffix: "arka plan", ext: "png")
        try write(result, uti: UTType.png.identifier, to: output, quality: 1, dpi: properties[kCGImagePropertyDPIWidth])
        return output
    }

    // MARK: Video and PDF

    public static func removeAudio(_ url: URL, folder: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw ConversionError.unreadable(url.lastPathComponent) }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ConversionError.writeFailed(url.lastPathComponent)
        }
        let range = try await video.load(.timeRange)
        try track.insertTimeRange(range, of: video, at: .zero)
        track.preferredTransform = try await video.load(.preferredTransform)
        let ext = url.pathExtension.lowercased() == "mov" ? "mov" : "mp4"
        let output = self.output(for: url, in: folder, suffix: "sessiz", ext: ext)
        try await FileConverter.export(composition, preset: AVAssetExportPresetPassthrough, fileType: ext == "mov" ? .mov : .mp4, to: output, progress: progress)
        return output
    }

    public static func mergePDFs(_ urls: [URL], folder: URL) throws -> URL {
        let merged = PDFDocument()
        for url in urls {
            guard let document = PDFDocument(url: url) else { throw ConversionError.unreadable(url.lastPathComponent) }
            for index in 0..<document.pageCount {
                if let page = document.page(at: index) { merged.insert(page, at: merged.pageCount) }
            }
        }
        guard let first = urls.first else { throw ConversionError.unsupported("") }
        let output = self.output(for: first, in: folder, suffix: "birleşik", ext: "pdf")
        guard merged.write(to: output) else { throw ConversionError.writeFailed(output.lastPathComponent) }
        return output
    }

    // MARK: Archives

    /// One item keeps its name (`Rapor.zip`); several become `Arşiv.zip`.
    public static func zip(_ urls: [URL], folder: URL) async throws -> URL {
        guard let first = urls.first else { throw ConversionError.unsupported("") }
        let clean = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn"]
        if urls.count == 1 {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: first.path, isDirectory: &isDirectory)
            let output = FileConverter.uniqueURL(in: folder, base: first.deletingPathExtension().lastPathComponent, ext: "zip")
            // A folder keeps its own name inside the archive; a single file sits at the top level.
            try await ExternalTools.run(URL(fileURLWithPath: "/usr/bin/ditto"), clean + (isDirectory.boolValue ? ["--keepParent"] : []) + [first.path, output.path],
                                        name: first.lastPathComponent)
            return output
        }
        // Gather everything into one folder so items from different places sit side by side in the archive.
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = staging.appendingPathComponent("Arşiv", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for url in urls {
            var target = root.appendingPathComponent(url.lastPathComponent)
            var counter = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = root.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(counter)" + (url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"))
                counter += 1
            }
            try FileManager.default.copyItem(at: url, to: target)
        }
        let output = FileConverter.uniqueURL(in: folder, base: "Arşiv", ext: "zip")
        try await ExternalTools.run(URL(fileURLWithPath: "/usr/bin/ditto"), clean + [root.path, output.path], name: "Arşiv.zip")
        return output
    }

    public static func unzip(_ url: URL, folder: URL) async throws -> URL {
        let output = FileConverter.uniqueFolder(in: folder, name: url.deletingPathExtension().lastPathComponent)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await ExternalTools.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", url.path, output.path], name: url.lastPathComponent)
        return output
    }
}
