import AVFoundation
import CoreGraphics
import XCTest
@testable import FastShotCore

final class AnnotationGeometryTests: XCTestCase {
    func testRectangleHitsOnlyItsOutlineUnlessFilled() {
        var a = Annotation(kind: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 60)], lineWidth: 4)
        XCTAssertTrue(a.contains(CGPoint(x: 10, y: 35), tolerance: 2))
        XCTAssertFalse(a.contains(CGPoint(x: 60, y: 35), tolerance: 2))
        a.filled = true
        XCTAssertTrue(a.contains(CGPoint(x: 60, y: 35), tolerance: 2))
    }

    func testArrowHitAndResizeKeepsOtherEnd() {
        let a = Annotation(kind: .arrow, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])
        XCTAssertTrue(a.contains(CGPoint(x: 50, y: 3), tolerance: 2))
        let moved = Annotation.resized(a, handle: .end, to: CGPoint(x: 80, y: 40), constrain: false)
        XCTAssertEqual(moved.points[0], CGPoint(x: 0, y: 0))
        XCTAssertEqual(moved.points[1], CGPoint(x: 80, y: 40))
    }

    func testPenScalesWithItsBox() {
        let pen = Annotation(kind: .pen, points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 0)])
        let wider = Annotation.resized(pen, handle: .right, to: CGPoint(x: 40, y: 5), constrain: false)
        XCTAssertEqual(wider.points.map(\.x), [0, 20, 40])
        XCTAssertEqual(wider.points.map(\.y), [0, 10, 0])
    }

    func testSnapAngleLocksTo45Degrees() {
        let p = Geometry.snapAngle(from: .zero, to: CGPoint(x: 100, y: 8))
        XCTAssertEqual(p.y, 0, accuracy: 0.001)
        XCTAssertEqual(p.x, hypot(100, 8), accuracy: 0.001)
    }

    func testVisibilityWindow() {
        let a = Annotation(kind: .line, points: [.zero, CGPoint(x: 5, y: 5)], start: 1, end: 2)
        XCTAssertFalse(a.isVisible(at: 0.5))
        XCTAssertTrue(a.isVisible(at: 1.5))
        XCTAssertFalse(a.isVisible(at: 2.5))
        XCTAssertTrue(Annotation(kind: .line, points: [], start: 1).isVisible(at: 99))
    }

    func testTextGrowsWithContent() {
        let short = AnnotationRenderer.textBoxSize("Hi", fontSize: 20)
        let long = AnnotationRenderer.textBoxSize("Merhaba dünya", fontSize: 20)
        let twoLines = AnnotationRenderer.textBoxSize("Merhaba\ndünya", fontSize: 20)
        XCTAssertGreaterThan(long.width, short.width)
        XCTAssertGreaterThan(twoLines.height, long.height * 1.6)
    }
}

final class ProjectTests: XCTestCase {
    func testProjectRoundTripsThroughLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ProjectLibrary(root: root)
        var project = try library.makeProject(kind: .image, canvasSize: CGSize(width: 100, height: 50), pixelScale: 2, mediaExtension: "png")
        project.annotations = [Annotation(kind: .text, points: [CGPoint(x: 4, y: 4)], color: .blue, text: "Not")]
        try Data([0]).write(to: library.mediaURL(project))
        try library.save(project)
        let loaded = try XCTUnwrap(library.allProjects().first)
        XCTAssertEqual(loaded.id, project.id)
        XCTAssertEqual(loaded.annotations, project.annotations)

        let package = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).fastshot")
        defer { try? FileManager.default.removeItem(at: package) }
        try library.exportPackage(loaded, to: package)
        let copy = try library.importPackage(at: package)
        XCTAssertNotEqual(copy.id, project.id)
        XCTAssertEqual(library.allProjects().count, 2)
    }

    func testTrimRangeClamps() {
        var project = CaptureProject(kind: .video, canvasSize: .zero, pixelScale: 1, mediaFile: "x.mp4")
        project.duration = 10
        project.trimStart = -2
        project.trimEnd = 4
        XCTAssertEqual(project.trimRange, 0...4)
    }
}

final class RenderingTests: XCTestCase {
    func testFlattenPaintsAnnotationsAtPixelScale() throws {
        let background = try XCTUnwrap(solidImage(width: 200, height: 100, color: .white))
        let box = Annotation(kind: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 40)], color: .red, filled: true)
        let image = try XCTUnwrap(ImageExporter.flatten(background: background, canvasSize: CGSize(width: 100, height: 50), annotations: [box]))
        XCTAssertEqual(image.width, 200)
        let inside = pixel(image, x: 50, y: 50), outside = pixel(image, x: 150, y: 20)
        XCTAssertGreaterThan(inside.r, 200)
        XCTAssertLessThan(inside.g, 100)
        XCTAssertGreaterThan(outside.g, 240)
    }

    func testPixelateAveragesBlocks() throws {
        // Left half black, right half white: a pixelated strip across the seam turns grey somewhere.
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        ctx.setFillColor(.black); ctx.fill(CGRect(x: 0, y: 0, width: 30, height: 64))
        let background = try XCTUnwrap(ctx.makeImage())
        let blur = Annotation(kind: .pixelate, points: [CGPoint(x: 0, y: 0), CGPoint(x: 64, y: 64)], lineWidth: 12)
        let image = try XCTUnwrap(ImageExporter.flatten(background: background, canvasSize: CGSize(width: 64, height: 64), annotations: [blur]))
        let values = (0..<64).map { pixel(image, x: $0, y: 32).r }
        XCTAssertTrue(values.contains { $0 > 40 && $0 < 215 }, "expected a blended block, got \(values)")
    }

    func testVideoExportBurnsTimedAnnotations() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4")
        try await makeSolidVideo(to: source, width: 320, height: 240, seconds: 2)

        // Canvas in points at 2x: the box covers pixels 40...120 and shows only during the second half.
        let box = Annotation(kind: .rectangle, points: [CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 60)], color: .red, filled: true, start: 1.0, end: 2.0)
        let request = VideoExportRequest(source: source, canvasSize: CGSize(width: 160, height: 120), annotations: [box])
        let output = folder.appendingPathComponent("out.mp4")
        try await VideoExporter.export(request, to: output, format: .mp4) { _ in }

        let early = try await VideoExporter.frame(of: output, at: 0.4)
        let late = try await VideoExporter.frame(of: output, at: 1.5)
        XCTAssertLessThan(pixel(early, x: 80, y: 80).r, 80, "annotation must be hidden before its start")
        XCTAssertGreaterThan(pixel(late, x: 80, y: 80).r, 180, "annotation must be visible inside its range")
        XCTAssertLessThan(pixel(late, x: 250, y: 200).r, 80, "frame outside the box keeps the source")

        let trimmed = folder.appendingPathComponent("trim.mp4")
        var trimRequest = request
        trimRequest.trim = 0.5...1.5
        try await VideoExporter.export(trimRequest, to: trimmed, format: .mp4) { _ in }
        let trimmedDuration = try await AVURLAsset(url: trimmed).load(.duration).seconds
        XCTAssertEqual(trimmedDuration, 1.0, accuracy: 0.15)

        let gif = folder.appendingPathComponent("out.gif")
        try await VideoExporter.export(trimRequest, to: gif, format: .gif) { _ in }
        let gifSource = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        XCTAssertGreaterThanOrEqual(CGImageSourceGetCount(gifSource), 10)
    }

    // MARK: Helpers

    private func solidImage(width: Int, height: Int, color: CGColor) -> CGImage? {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.setFillColor(color)
        ctx?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx?.makeImage()
    }

    /// Reads a pixel addressed from the image's top-left corner.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }
}
