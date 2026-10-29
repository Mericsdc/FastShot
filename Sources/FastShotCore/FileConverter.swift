import AVFoundation
import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public enum FileFamily: String, Sendable {
    case image, video, audio, pdf, document

    public var title: String {
        switch self {
        case .image: return "Görüntü"
        case .video: return "Video"
        case .audio: return "Ses"
        case .pdf: return "PDF"
        case .document: return "Belge"
        }
    }

    public var symbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .pdf: return "doc.richtext"
        case .document: return "doc.text"
        }
    }
}

public enum AudioTarget: String, Hashable, Sendable { case m4a, wav, aiff, caf, flac, mp3 }
public enum DocumentTarget: String, Hashable, Sendable { case docx, doc, odt, rtf, txt, html }

/// One choice on the conversion wheel.
public struct ConversionFormat: Hashable, Identifiable, Sendable {
    public enum Kind: Hashable, Sendable {
        case image(uti: String)
        case webp
        case imagesToPDF
        case video(preset: String, fileType: String)
        case gif
        case audio(AudioTarget)
        case pdfPages(uti: String)
        case pdfText(DocumentTarget)
        case document(DocumentTarget)
        case documentToPDF
    }

    public let id: String
    public let title: String
    public let fileExtension: String
    public let detail: String?
    public let kind: Kind

    init(_ id: String, _ title: String, ext: String, detail: String? = nil, _ kind: Kind) {
        self.id = id
        self.title = title
        self.fileExtension = ext
        self.detail = detail
        self.kind = kind
    }
}

public enum ConversionError: LocalizedError {
    case unreadable(String)
    case writeFailed(String)
    case noAudio(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "\(name) okunamadı."
        case .writeFailed(let name): return "\(name) yazılamadı."
        case .noAudio(let name): return "\(name) içinde ses yok."
        case .unsupported(let name): return "\(name) bu biçime dönüştürülemiyor."
        }
    }
}

/// Converts files between formats using macOS's own engines (ImageIO, AVFoundation,
/// PDFKit, Cocoa text). WebP and MP3, which macOS cannot write, use `cwebp`, `lame`
/// or `ffmpeg` when one is installed.
public enum FileConverter {
    // MARK: What can be converted

    static let documentTypes: [UTType] = [
        .rtf, .rtfd, .plainText, .html, .webArchive,
        UTType("org.openxmlformats.wordprocessingml.document"), UTType("com.microsoft.word.doc"),
        UTType("org.oasis-open.opendocument.text"), UTType("net.daringfireball.markdown"),
    ].compactMap { $0 }

    public static func family(of url: URL) -> FileFamily? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) {
            let readable = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
            return readable.contains(type.identifier) || type.conforms(to: .jpeg) || type.conforms(to: .png) ? .image : nil
        }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if documentTypes.contains(where: { type.conforms(to: $0) }) { return .document }
        return nil
    }

    public static func targets(for family: FileFamily) -> [ConversionFormat] {
        let writable = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
        switch family {
        case .image:
            var list: [ConversionFormat] = [
                .init("png", "PNG", ext: "png", detail: "Kayıpsız", .image(uti: "public.png")),
                .init("jpeg", "JPEG", ext: "jpg", .image(uti: "public.jpeg")),
                .init("heic", "HEIC", ext: "heic", detail: "Küçük", .image(uti: "public.heic")),
            ]
            if ExternalTools.webp != nil { list.append(.init("webp", "WEBP", ext: "webp", detail: "Web", .webp)) }
            list += [
                .init("pdf", "PDF", ext: "pdf", .imagesToPDF),
                .init("tiff", "TIFF", ext: "tiff", .image(uti: "public.tiff")),
                .init("avif", "AVIF", ext: "avif", .image(uti: "public.avif")),
                .init("gif", "GIF", ext: "gif", .image(uti: "com.compuserve.gif")),
                .init("bmp", "BMP", ext: "bmp", .image(uti: "com.microsoft.bmp")),
            ]
            return list.filter { format in
                if case .image(let uti) = format.kind { return writable.contains(uti) }
                return true
            }
        case .video:
            var list: [ConversionFormat] = [
                .init("mp4", "MP4", ext: "mp4", detail: "H.264", .video(preset: AVAssetExportPresetHighestQuality, fileType: AVFileType.mp4.rawValue)),
                .init("mov", "MOV", ext: "mov", .video(preset: AVAssetExportPresetHighestQuality, fileType: AVFileType.mov.rawValue)),
                .init("hevc", "HEVC", ext: "mp4", detail: "Küçük", .video(preset: AVAssetExportPresetHEVCHighestQuality, fileType: AVFileType.mp4.rawValue)),
                .init("gif", "GIF", ext: "gif", .gif),
                .init("m4a", "M4A", ext: "m4a", detail: "Ses", .audio(.m4a)),
                .init("wav", "WAV", ext: "wav", detail: "Ses", .audio(.wav)),
            ]
            if ExternalTools.mp3 != nil { list.append(.init("mp3", "MP3", ext: "mp3", detail: "Ses", .audio(.mp3))) }
            return list
        case .audio:
            var list: [ConversionFormat] = [
                .init("m4a", "M4A", ext: "m4a", detail: "AAC", .audio(.m4a)),
                .init("wav", "WAV", ext: "wav", .audio(.wav)),
                .init("aiff", "AIFF", ext: "aiff", .audio(.aiff)),
                .init("flac", "FLAC", ext: "flac", detail: "Kayıpsız", .audio(.flac)),
                .init("caf", "CAF", ext: "caf", .audio(.caf)),
            ]
            if ExternalTools.mp3 != nil { list.insert(.init("mp3", "MP3", ext: "mp3", .audio(.mp3)), at: 1) }
            return list
        case .pdf:
            return [
                .init("png", "PNG", ext: "png", detail: "Sayfalar", .pdfPages(uti: "public.png")),
                .init("jpeg", "JPEG", ext: "jpg", detail: "Sayfalar", .pdfPages(uti: "public.jpeg")),
                .init("heic", "HEIC", ext: "heic", detail: "Sayfalar", .pdfPages(uti: "public.heic")),
                .init("tiff", "TIFF", ext: "tiff", detail: "Sayfalar", .pdfPages(uti: "public.tiff")),
                .init("txt", "TXT", ext: "txt", detail: "Metin", .pdfText(.txt)),
                .init("rtf", "RTF", ext: "rtf", .pdfText(.rtf)),
                .init("docx", "DOCX", ext: "docx", detail: "Word", .pdfText(.docx)),
            ]
        case .document:
            return [
                .init("pdf", "PDF", ext: "pdf", .documentToPDF),
                .init("docx", "DOCX", ext: "docx", detail: "Word", .document(.docx)),
                .init("rtf", "RTF", ext: "rtf", .document(.rtf)),
                .init("txt", "TXT", ext: "txt", .document(.txt)),
                .init("html", "HTML", ext: "html", .document(.html)),
                .init("odt", "ODT", ext: "odt", .document(.odt)),
                .init("doc", "DOC", ext: "doc", detail: "Word 97", .document(.doc)),
            ]
        }
    }

    /// Formats every dropped file can become, minus the format they already share.
    public static func targets(for urls: [URL]) -> [ConversionFormat] {
        let families = Set(urls.compactMap(family(of:)))
        guard families.count == 1, let family = families.first, urls.allSatisfy({ self.family(of: $0) != nil }) else { return [] }
        let extensions = Set(urls.map { normalized($0.pathExtension) })
        return targets(for: family).filter { format in
            !(extensions.count == 1 && extensions.first == normalized(format.fileExtension) && format.id != "hevc")
        }
    }

    static func normalized(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpeg", "jpe": return "jpg"
        case "tif": return "tiff"
        case "aif": return "aiff"
        case "htm": return "html"
        default: return ext.lowercased()
        }
    }

    // MARK: Converting

    /// Converts the files, writing results into `folder(for:)`. Several images going to PDF become one document.
    public static func convert(_ urls: [URL], to format: ConversionFormat, folder: (URL) -> URL, quality: Double = 0.9,
                               progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        if case .imagesToPDF = format.kind, urls.count > 1 {
            let base = urls[0].deletingPathExtension().lastPathComponent
            let output = uniqueURL(in: folder(urls[0]), base: base, ext: "pdf")
            try imagesToPDF(urls, to: output)
            progress(1)
            return [output]
        }
        var outputs: [URL] = []
        for (index, url) in urls.enumerated() {
            let base = Double(index) / Double(urls.count)
            let share = 1 / Double(urls.count)
            outputs += try await convert(url, to: format, folder: folder(url), quality: quality) { fraction in
                progress(base + fraction * share)
            }
        }
        progress(1)
        return outputs
    }

    public static func convert(_ url: URL, to format: ConversionFormat, folder: URL, quality: Double = 0.9,
                               progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [URL] {
        let base = url.deletingPathExtension().lastPathComponent
        let output = uniqueURL(in: folder, base: base, ext: format.fileExtension)
        switch format.kind {
        case .image(let uti):
            try convertImage(url, uti: uti, to: output, quality: quality)
        case .webp:
            try await convertToWebP(url, to: output, quality: quality)
        case .imagesToPDF:
            try imagesToPDF([url], to: output)
        case .video(let preset, let fileType):
            try await convertVideo(url, preset: preset, fileType: AVFileType(fileType), to: output, progress: progress)
        case .gif:
            try await VideoExporter.exportGIF(VideoExportRequest(source: url, canvasSize: .zero, annotations: []), to: output, progress: progress)
        case .audio(let target):
            try await convertAudio(url, to: target, output: output, progress: progress)
        case .pdfPages(let uti):
            return try pdfToImages(url, uti: uti, ext: format.fileExtension, folder: folder, quality: quality)
        case .pdfText(let target):
            try await MainActor.run { try writeDocument(try pdfText(url), as: target, to: output) }
        case .document(let target):
            try await MainActor.run { try writeDocument(try readDocument(url), as: target, to: output) }
        case .documentToPDF:
            try await MainActor.run { try documentToPDF(try readDocument(url), to: output) }
        }
        progress(1)
        return [output]
    }

    public static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return url
    }

    static func uniqueFolder(in folder: URL, name: String) -> URL {
        var url = folder.appendingPathComponent(name, isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(counter)", isDirectory: true)
            counter += 1
        }
        return url
    }

    // MARK: Images

    static func orientedImage(_ source: CGImageSource) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0, height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1), kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func convertImage(_ url: URL, uti: String, to output: URL, quality: Double) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, uti as CFString, 1, nil) else {
            throw ConversionError.unsupported(url.lastPathComponent)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if hasAlpha, uti == UTType.jpeg.identifier || uti == UTType.bmp.identifier {
            // These formats can't hold transparency; put it on white instead of black.
            guard let image = orientedImage(source), let flat = flattened(image) else { throw ConversionError.unreadable(url.lastPathComponent) }
            var flatOptions = options
            for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] { flatOptions[key] = properties[key] }
            CGImageDestinationAddImage(destination, flat, flatOptions as CFDictionary)
        } else {
            CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw ConversionError.writeFailed(output.lastPathComponent)
        }
    }

    static func flattened(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    static func imagesToPDF(_ urls: [URL], to output: URL) throws {
        guard let ctx = CGContext(output as CFURL, mediaBox: nil, [kCGPDFContextCreator: "FastShot"] as CFDictionary) else {
            throw ConversionError.writeFailed(output.lastPathComponent)
        }
        var pages = 0
        for url in urls {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = orientedImage(source) else { continue }
            let scale = ImageExporter.pointScale(of: url) ?? 1
            var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            ctx.beginPage(mediaBox: &box)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: box)
            ctx.endPage()
            pages += 1
        }
        ctx.closePDF()
        if pages == 0 {
            try? FileManager.default.removeItem(at: output)
            throw ConversionError.unreadable(urls.first?.lastPathComponent ?? "")
        }
    }

    static func convertToWebP(_ url: URL, to output: URL, quality: Double) async throws {
        guard let tool = ExternalTools.webp else { throw ConversionError.unsupported(url.lastPathComponent) }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try convertImage(url, uti: UTType.png.identifier, to: temporary, quality: 1)
        let q = String(Int(quality * 100))
        let arguments = tool.lastPathComponent == "cwebp" ? ["-quiet", "-q", q, temporary.path, "-o", output.path]
                                                          : ["-y", "-loglevel", "error", "-i", temporary.path, "-quality", q, output.path]
        try await ExternalTools.run(tool, arguments, name: url.lastPathComponent)
    }

    // MARK: Video

    static func convertVideo(_ url: URL, preset: String, fileType: AVFileType, to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: url)
        // Changing only the container is lossless and fast; re-encode when that isn't possible.
        if preset != AVAssetExportPresetHEVCHighestQuality,
           await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: fileType) {
            do {
                try await export(asset, preset: AVAssetExportPresetPassthrough, fileType: fileType, to: output, progress: progress)
                return
            } catch {
                try? FileManager.default.removeItem(at: output)
            }
        }
        try await export(asset, preset: preset, fileType: fileType, to: output, progress: progress)
    }

    static func export(_ asset: AVAsset, preset: String, fileType: AVFileType, to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw ConversionError.unsupported(output.lastPathComponent) }
        session.shouldOptimizeForNetworkUse = true
        let monitor = Task {
            for await state in session.states(updateInterval: 0.2) {
                if case .exporting(let fraction) = state { progress(fraction.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: output, as: fileType)
    }

    // MARK: Audio

    static func convertAudio(_ url: URL, to target: AudioTarget, output: URL, bitRate: Int? = nil,
                             progress: @escaping @Sendable (Double) -> Void) async throws {
        if target == .mp3 {
            try await convertToMP3(url, output: output, progress: progress)
            return
        }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ConversionError.noAudio(url.lastPathComponent) }
        let duration = try await asset.load(.duration).seconds
        let description = try await track.load(.formatDescriptions).first
        let source = description.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let channels = max(1, min(Int(source?.mChannelsPerFrame ?? 2), 2))
        var sampleRate = source?.mSampleRate ?? 44_100
        if sampleRate <= 0 { sampleRate = 44_100 }
        if target == .m4a { sampleRate = min(sampleRate, 48_000) }

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
        ])
        reader.add(readerOutput)
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false),
              reader.startReading() else { throw ConversionError.unreadable(url.lastPathComponent) }
        let file = try AVAudioFile(forWriting: output, settings: settings(for: target, sampleRate: sampleRate, channels: channels, bitRate: bitRate),
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        var seconds = 0.0
        while let sample = readerOutput.copyNextSampleBuffer() {
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(frames)) else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else {
                throw ConversionError.unreadable(url.lastPathComponent)
            }
            try file.write(from: buffer)
            seconds += Double(frames) / sampleRate
            if duration > 0 { progress(min(0.99, seconds / duration)) }
        }
        if reader.status == .failed { throw reader.error ?? ConversionError.unreadable(url.lastPathComponent) }
    }

    static func settings(for target: AudioTarget, sampleRate: Double, channels: Int, bitRate: Int? = nil) -> [String: Any] {
        let common: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]
        func pcm(bigEndian: Bool) -> [String: Any] {
            common.merging([AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                            AVLinearPCMIsBigEndianKey: bigEndian, AVLinearPCMIsNonInterleaved: false]) { $1 }
        }
        switch target {
        case .m4a: return common.merging([AVFormatIDKey: kAudioFormatMPEG4AAC, AVEncoderBitRateKey: bitRate ?? (channels > 1 ? 256_000 : 128_000)]) { $1 }
        case .wav, .caf: return pcm(bigEndian: false)
        case .aiff: return pcm(bigEndian: true)
        case .flac: return common.merging([AVFormatIDKey: kAudioFormatFLAC]) { $1 }
        case .mp3: return [:]
        }
    }

    static func convertToMP3(_ url: URL, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let tool = ExternalTools.mp3 else { throw ConversionError.unsupported(url.lastPathComponent) }
        if tool.lastPathComponent == "ffmpeg" {
            try await ExternalTools.run(tool, ["-y", "-loglevel", "error", "-i", url.path, "-vn", "-codec:a", "libmp3lame", "-q:a", "2", output.path],
                                        name: url.lastPathComponent)
        } else {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await convertAudio(url, to: .wav, output: temporary) { progress($0 * 0.6) }
            try await ExternalTools.run(tool, ["--quiet", "-V2", temporary.path, output.path], name: url.lastPathComponent)
        }
    }

    // MARK: PDF

    static func pdfToImages(_ url: URL, uti: String, ext: String, folder: URL, quality: Double) throws -> [URL] {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else { throw ConversionError.unreadable(url.lastPathComponent) }
        let base = url.deletingPathExtension().lastPathComponent
        let pages = document.numberOfPages
        var target = folder
        if pages > 1 {
            target = uniqueFolder(in: folder, name: "\(base) (\(ext.uppercased()))")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        }
        var outputs: [URL] = []
        let scale: CGFloat = 2
        for number in 1...pages {
            guard let page = document.page(at: number) else { continue }
            let box = page.getBoxRect(.cropBox)
            let rotated = page.rotationAngle % 180 != 0
            let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
            let width = Int(size.width * scale), height = Int(size.height * scale)
            guard width > 0, height > 0,
                  let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.scaleBy(x: scale, y: scale)
            ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(page)
            guard let image = ctx.makeImage() else { continue }
            let name = pages > 1 ? "\(base) - \(number)" : base
            let output = uniqueURL(in: target, base: name, ext: ext)
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, uti as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality,
                                                            kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
            if CGImageDestinationFinalize(destination) { outputs.append(output) }
        }
        guard !outputs.isEmpty else { throw ConversionError.writeFailed(base) }
        return pages > 1 ? [target] : outputs
    }

    static func pdfText(_ url: URL) throws -> NSAttributedString {
        guard let document = PDFDocument(url: url) else { throw ConversionError.unreadable(url.lastPathComponent) }
        let text = NSMutableAttributedString()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            if let content = page.attributedString { text.append(content) } else if let plain = page.string { text.append(NSAttributedString(string: plain)) }
            if index < document.pageCount - 1 { text.append(NSAttributedString(string: "\n\n")) }
        }
        return text
    }

    // MARK: Documents

    @MainActor
    static func readDocument(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        if ext == "md" || ext == "markdown" {
            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .inlineOnlyPreservingWhitespace
            return NSAttributedString(try AttributedString(markdown: try Data(contentsOf: url), options: options))
        }
        do {
            return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        } catch {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
    }

    @MainActor
    static func writeDocument(_ text: NSAttributedString, as target: DocumentTarget, to output: URL) throws {
        if target == .txt {
            try text.string.write(to: output, atomically: true, encoding: .utf8)
            return
        }
        let types: [DocumentTarget: NSAttributedString.DocumentType] = [
            .docx: .officeOpenXML, .doc: .docFormat, .odt: .openDocument, .rtf: .rtf, .html: .html,
        ]
        guard let type = types[target] else { throw ConversionError.unsupported(output.lastPathComponent) }
        let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type])
        try data.write(to: output, options: .atomic)
    }

    /// Lays text out on A4 pages and writes a PDF.
    @MainActor
    static func documentToPDF(_ text: NSAttributedString, to output: URL) throws {
        var page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let margin: CGFloat = 56
        guard let ctx = CGContext(output as CFURL, mediaBox: &page, [kCGPDFContextCreator: "FastShot"] as CFDictionary) else {
            throw ConversionError.writeFailed(output.lastPathComponent)
        }
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let previous = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previous }
        while true {
            let container = NSTextContainer(size: CGSize(width: page.width - margin * 2, height: page.height - margin * 2))
            layout.addTextContainer(container)
            let range = layout.glyphRange(for: container)
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: page.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            layout.drawBackground(forGlyphRange: range, at: CGPoint(x: margin, y: margin))
            layout.drawGlyphs(forGlyphRange: range, at: CGPoint(x: margin, y: margin))
            ctx.restoreGState()
            ctx.endPDFPage()
            if range.length == 0 || NSMaxRange(range) >= layout.numberOfGlyphs { break }
        }
        ctx.closePDF()
    }
}

/// Optional command-line encoders for formats macOS can't write itself.
public enum ExternalTools {
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    static func find(_ name: String) -> URL? {
        searchPaths.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static var webp: URL? { find("cwebp") ?? find("ffmpeg") }
    public static var mp3: URL? { find("ffmpeg") ?? find("lame") }

    static func run(_ tool: URL, _ arguments: [String], name: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ConversionError.writeFailed(name))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}
