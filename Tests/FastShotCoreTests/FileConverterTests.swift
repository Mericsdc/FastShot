import AVFoundation
import AppKit
import PDFKit
import XCTest
@testable import FastShotCore

final class FileConverterTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("conv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func format(_ id: String, for url: URL) throws -> ConversionFormat {
        try XCTUnwrap(FileConverter.targets(for: [url]).first { $0.id == id }, "no \(id) target for \(url.lastPathComponent)")
    }

    private func convert(_ url: URL, _ id: String) async throws -> URL {
        let outputs = try await FileConverter.convert([url], to: try format(id, for: url), folder: { _ in self.folder }) { _ in }
        let output = try XCTUnwrap(outputs.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), output.path)
        return output
    }

    // MARK: Targets

    func testTargetsSkipTheSourceFormatAndMixedFamilies() throws {
        let png = folder.appendingPathComponent("a.png"), wav = folder.appendingPathComponent("b.wav")
        let imageTargets = FileConverter.targets(for: [png]).map(\.id)
        XCTAssertFalse(imageTargets.contains("png"))
        XCTAssertTrue(imageTargets.contains("jpeg"))
        XCTAssertTrue(imageTargets.contains("pdf"))
        XCTAssertEqual(FileConverter.targets(for: [png, wav]), [])
        XCTAssertEqual(FileConverter.family(of: folder.appendingPathComponent("x.docx")), .document)
        XCTAssertEqual(FileConverter.family(of: folder.appendingPathComponent("x.mov")), .video)
        XCTAssertEqual(FileConverter.family(of: folder.appendingPathComponent("x.pdf")), .pdf)
        XCTAssertNil(FileConverter.family(of: folder.appendingPathComponent("x.zip")))
    }

    // MARK: Images

    func testImageConversionsAndTransparencyOnJPEG() async throws {
        let png = try makeTransparentPNG()
        for id in ["jpeg", "heic", "tiff", "avif", "gif", "bmp"] {
            let output = try await convert(png, id)
            let image = try XCTUnwrap(ImageExporter.load(output), id)
            XCTAssertEqual(image.width, 40, id)
        }
        let jpeg = folder.appendingPathComponent("transparent.jpg")
        let image = try XCTUnwrap(ImageExporter.load(jpeg))
        XCTAssertGreaterThan(pixelRed(image, x: 35, y: 5), 240, "transparent area must become white, not black")
    }

    func testSeveralImagesBecomeOnePDF() async throws {
        let first = try makeTransparentPNG(name: "one")
        let second = try makeTransparentPNG(name: "two")
        let pdf = try XCTUnwrap(FileConverter.targets(for: [first, second]).first { $0.id == "pdf" })
        let outputs = try await FileConverter.convert([first, second], to: pdf, folder: { _ in self.folder }) { _ in }
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(PDFDocument(url: outputs[0])?.pageCount, 2)
    }

    // MARK: Documents and PDF

    func testDocumentsConvertBetweenFormatsAndToPDF() async throws {
        let rtf = folder.appendingPathComponent("not.rtf")
        let text = NSAttributedString(string: "Merhaba FastShot\nİkinci satır", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            .write(to: rtf)
        for id in ["docx", "odt", "html", "txt", "doc"] { _ = try await convert(rtf, id) }
        let docx = folder.appendingPathComponent("not.docx")
        let backToText = try await convert(docx, "txt")
        XCTAssertTrue(try String(contentsOf: backToText, encoding: .utf8).contains("İkinci satır"))

        let pdf = try await convert(rtf, "pdf")
        XCTAssertEqual(PDFDocument(url: pdf)?.pageCount, 1)
        XCTAssertTrue(PDFDocument(url: pdf)?.string?.contains("Merhaba FastShot") ?? false)

        let pageImage = try await convert(pdf, "png")
        XCTAssertNotNil(ImageExporter.load(pageImage))
        let extracted = folder.appendingPathComponent("not (2).txt")
        _ = try await convert(pdf, "txt")
        XCTAssertTrue(try String(contentsOf: extracted, encoding: .utf8).contains("Merhaba"))
    }

    func testLongDocumentPaginatesAndMultiPagePDFBecomesAFolder() async throws {
        let txt = folder.appendingPathComponent("uzun.txt")
        try (1...200).map { "Satır \($0)" }.joined(separator: "\n").write(to: txt, atomically: true, encoding: .utf8)
        let pdf = try await convert(txt, "pdf")
        let pages = try XCTUnwrap(PDFDocument(url: pdf)?.pageCount)
        XCTAssertGreaterThan(pages, 2)
        let pagesFolder = try await convert(pdf, "jpeg")
        let files = try FileManager.default.contentsOfDirectory(atPath: pagesFolder.path)
        XCTAssertEqual(files.count, pages)
    }

    // MARK: Audio and video

    func testAudioConversions() async throws {
        let wav = try makeTone(seconds: 1)
        for id in ["m4a", "flac", "aiff", "caf"] {
            let output = try await convert(wav, id)
            let duration = try await AVURLAsset(url: output).load(.duration).seconds
            XCTAssertEqual(duration, 1, accuracy: 0.1, id)
        }
    }

    func testVideoConversions() async throws {
        let mp4 = folder.appendingPathComponent("klip.mp4")
        try await makeSolidVideo(to: mp4, width: 160, height: 120, seconds: 1)
        for id in ["mov", "hevc", "gif"] {
            let output = try await convert(mp4, id)
            XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int ?? 0, 0, id)
        }
        do {
            _ = try await convert(mp4, "m4a")
            XCTFail("a silent video has nothing to extract")
        } catch ConversionError.noAudio {
        }
    }

    // MARK: Optional encoders

    func testWebPAndMP3WhenEncodersAreInstalled() async throws {
        guard ExternalTools.webp != nil, ExternalTools.mp3 != nil else {
            throw XCTSkip("cwebp/lame (or ffmpeg) not installed")
        }
        let png = try makeTransparentPNG()
        let webp = try await convert(png, "webp")
        XCTAssertEqual(ImageExporter.load(webp)?.width, 40)

        let wav = try makeTone(seconds: 1)
        let mp3 = try await convert(wav, "mp3")
        let duration = try await AVURLAsset(url: mp3).load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.15)
    }

    // MARK: Helpers

    private func makeTransparentPNG(name: String = "transparent") throws -> URL {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.4, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
        let url = folder.appendingPathComponent("\(name).png")
        try XCTUnwrap(ImageExporter.encode(try XCTUnwrap(ctx.makeImage()), format: .png)).write(to: url)
        return url
    }

    private func makeTone(seconds: Double) throws -> URL {
        let url = folder.appendingPathComponent("ton.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100,
                                                               AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16])
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<2 {
            let samples = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) { samples[i] = sin(Float(i) * 2 * .pi * 440 / 44_100) * 0.3 }
        }
        try file.write(from: buffer)
        return url
    }

    private func pixelRed(_ image: CGImage, x: Int, y: Int) -> Int {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return Int(data[0])
    }
}
