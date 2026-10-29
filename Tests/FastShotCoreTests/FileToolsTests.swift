import AVFoundation
import AppKit
import ImageIO
import PDFKit
import XCTest
@testable import FastShotCore

final class FileToolsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testWhichToolsAndActionsApply() {
        let jpg = folder.appendingPathComponent("a.jpg"), pdf1 = folder.appendingPathComponent("a.pdf"), pdf2 = folder.appendingPathComponent("b.pdf")
        XCTAssertEqual(FileTools.tools(for: [jpg]), [.edit, .crop, .background, .compress, .metadata, .recognizeText, .translate])
        XCTAssertTrue(FileTools.tools(for: [pdf1, pdf2]).contains(.mergePDF))
        XCTAssertFalse(FileTools.tools(for: [pdf1]).contains(.mergePDF))
        XCTAssertEqual(FileTools.tools(for: [jpg, pdf1]), [])
        XCTAssertEqual(FileTools.actions(for: [folder]).first, .zip)
        XCTAssertEqual(FileTools.actions(for: [folder.appendingPathComponent("x.zip")]).first, .unzip)
        XCTAssertTrue(FileTools.actions(for: [jpg]).contains(.pin))
        XCTAssertFalse(FileTools.actions(for: [pdf1]).contains(.pin))
    }

    func testCompressMakesAPhotoSmaller() throws {
        let jpg = try makePhoto(name: "foto", ext: "jpg", quality: 1)
        let output = try FileTools.compressImage(jpg, folder: folder)
        XCTAssertEqual(output.lastPathComponent, "foto (küçük).jpg")
        XCTAssertLessThan(try size(of: output), try size(of: jpg))
    }

    func testStripMetadataRemovesLocation() async throws {
        let jpg = try makePhoto(name: "konum", ext: "jpg", quality: 0.9, gps: true)
        XCTAssertNotNil(properties(of: jpg)[kCGImagePropertyGPSDictionary])
        let clean = try await FileTools.stripMetadata(jpg, folder: folder)
        XCTAssertNil(properties(of: clean)[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(properties(of: clean)[kCGImagePropertyPixelWidth] as? Int, 300)
    }

    func testCropAndBackground() throws {
        let png = try makePhoto(name: "ekran", ext: "png", quality: 1)
        let cropped = try FileTools.crop(png, to: CGRect(x: 10, y: 20, width: 120, height: 80), folder: folder)
        XCTAssertEqual(properties(of: cropped)[kCGImagePropertyPixelWidth] as? Int, 120)
        XCTAssertEqual(properties(of: cropped)[kCGImagePropertyPixelHeight] as? Int, 80)
        let framed = try FileTools.addBackground(png, folder: folder)
        XCTAssertGreaterThan(properties(of: framed)[kCGImagePropertyPixelWidth] as? Int ?? 0, 300)
    }

    func testMergePDFs() throws {
        let first = try makePDF(name: "bir", pages: 2), second = try makePDF(name: "iki", pages: 3)
        let merged = try FileTools.mergePDFs([first, second], folder: folder)
        XCTAssertEqual(PDFDocument(url: merged)?.pageCount, 5)
    }

    func testZipRoundTrip() async throws {
        let a = folder.appendingPathComponent("a.txt"), b = folder.appendingPathComponent("b.txt")
        try "bir".write(to: a, atomically: true, encoding: .utf8)
        try "iki".write(to: b, atomically: true, encoding: .utf8)
        let single = try await FileTools.zip([a], folder: folder)
        XCTAssertEqual(single.lastPathComponent, "a.zip")
        let singleOut = try await FileTools.unzip(single, folder: folder)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: singleOut.path), ["a.txt"], "a lone file sits at the top level")
        let archive = try await FileTools.zip([a, b], folder: folder)
        XCTAssertEqual(archive.lastPathComponent, "Arşiv.zip")
        let extracted = try await FileTools.unzip(archive, folder: folder)
        // Like Finder's "Compress N items", the items sit at the archive's top level.
        let contents = try FileManager.default.contentsOfDirectory(atPath: extracted.path).sorted()
        XCTAssertEqual(contents, ["a.txt", "b.txt"], "no __MACOSX clutter")
    }

    func testRemoveAudioAndCompressVideo() async throws {
        let mp4 = folder.appendingPathComponent("klip.mp4")
        try await makeSolidVideo(to: mp4, width: 160, height: 120, seconds: 1)
        let silent = try await FileTools.removeAudio(mp4, folder: folder)
        let tracks = try await AVURLAsset(url: silent).loadTracks(withMediaType: .audio)
        XCTAssertTrue(tracks.isEmpty)
        let small = try await FileTools.compress(mp4, folder: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: small.path))
    }

    // MARK: Helpers

    private func size(of url: URL) throws -> Int { try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0 }

    private func properties(of url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    /// A noisy 300×200 image, so compression has something to remove.
    private func makePhoto(name: String, ext: String, quality: Double, gps: Bool = false) throws -> URL {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        var seed: UInt64 = 42
        for y in stride(from: 0, to: 200, by: 2) {
            for x in stride(from: 0, to: 300, by: 2) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let v = CGFloat(seed >> 56) / 255
                ctx.setFillColor(CGColor(srgbRed: v, green: CGFloat(x) / 300, blue: CGFloat(y) / 200, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
            }
        }
        let url = folder.appendingPathComponent("\(name).\(ext)")
        let uti = ext == "png" ? "public.png" : "public.jpeg"
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil))
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if gps {
            options[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 41.01, kCGImagePropertyGPSLatitudeRef: "N",
                                                      kCGImagePropertyGPSLongitude: 28.97, kCGImagePropertyGPSLongitudeRef: "E"]
        }
        CGImageDestinationAddImage(destination, try XCTUnwrap(ctx.makeImage()), options as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func makePDF(name: String, pages: Int) throws -> URL {
        let url = folder.appendingPathComponent("\(name).pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.fill(CGRect(x: 20, y: 20, width: 50, height: 50))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }
}
