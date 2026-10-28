import CoreGraphics
import Foundation

public enum CaptureKind: String, Codable, Sendable {
    case image, video
}

/// A capture plus its annotations, kept separate so it can be reopened and
/// edited at any time. The original media is never modified.
public struct CaptureProject: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: CaptureKind
    public var createdAt: Date
    public var modifiedAt: Date
    /// Canvas size in points; the media's pixel size divided by `pixelScale`.
    public var canvasSize: CGSize
    public var pixelScale: Double
    public var mediaFile: String
    public var annotations: [Annotation]
    public var duration: Double?
    public var trimStart: Double?
    public var trimEnd: Double?

    public init(id: UUID = UUID(), kind: CaptureKind, canvasSize: CGSize, pixelScale: Double, mediaFile: String, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.modifiedAt = createdAt
        self.canvasSize = canvasSize
        self.pixelScale = pixelScale
        self.mediaFile = mediaFile
        self.annotations = []
    }

    /// The part of a recording that gets exported.
    public var trimRange: ClosedRange<Double>? {
        guard let duration, duration > 0 else { return nil }
        let start = max(0, min(trimStart ?? 0, duration))
        let end = max(start, min(trimEnd ?? duration, duration))
        return end - start > 0.05 ? start...end : nil
    }
}

public final class ProjectLibrary: @unchecked Sendable {
    public static let packageExtension = "fastshot"
    static let manifestName = "project.json"
    static let thumbnailName = "thumbnail.jpg"

    public let root: URL
    private let fileManager = FileManager.default

    public static var defaultRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("FastShot/Library", isDirectory: true)
    }

    public init(root: URL = ProjectLibrary.defaultRoot) {
        self.root = root
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func folder(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func mediaURL(_ project: CaptureProject) -> URL { folder(for: project.id).appendingPathComponent(project.mediaFile) }
    public func thumbnailURL(_ project: CaptureProject) -> URL { folder(for: project.id).appendingPathComponent(Self.thumbnailName) }

    /// Creates the folder for a new capture; the caller writes the media to `mediaURL`.
    public func makeProject(kind: CaptureKind, canvasSize: CGSize, pixelScale: Double, mediaExtension: String) throws -> CaptureProject {
        let project = CaptureProject(kind: kind, canvasSize: canvasSize, pixelScale: pixelScale, mediaFile: "original.\(mediaExtension)")
        try fileManager.createDirectory(at: folder(for: project.id), withIntermediateDirectories: true)
        return project
    }

    public func save(_ project: CaptureProject) throws {
        var project = project
        project.modifiedAt = Date()
        let folder = folder(for: project.id)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.encoder.encode(project).write(to: folder.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    public func project(id: UUID) -> CaptureProject? { try? Self.read(folder(for: id)) }

    public func allProjects() -> [CaptureProject] {
        let folders = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let project = try? Self.read(folder), fileManager.fileExists(atPath: mediaURL(project).path) else { return nil }
            return project
        }.sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(_ project: CaptureProject) throws {
        try fileManager.removeItem(at: folder(for: project.id))
    }

    public func writeThumbnail(_ image: CGImage, for project: CaptureProject) {
        guard let small = ImageExporter.scaled(image, maxSide: 520),
              let data = ImageExporter.encode(small, format: .jpeg, quality: 0.8) else { return }
        try? data.write(to: thumbnailURL(project), options: .atomic)
    }

    /// Copies a capture out as a self-contained `.fastshot` package that stays editable.
    public func exportPackage(_ project: CaptureProject, to url: URL) throws {
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        try fileManager.copyItem(at: folder(for: project.id), to: url)
    }

    /// Brings a `.fastshot` package into the library, as a copy if its id is already taken.
    public func importPackage(at url: URL) throws -> CaptureProject {
        var project = try Self.read(url)
        if fileManager.fileExists(atPath: folder(for: project.id).path) {
            if folder(for: project.id).standardizedFileURL == url.standardizedFileURL { return project }
            project.id = UUID()
        }
        try fileManager.copyItem(at: url, to: folder(for: project.id))
        try save(project)
        return project
    }

    /// Wraps an existing image or movie file in a new project. APFS clones the file, so large videos copy instantly.
    public func importMedia(at url: URL, kind: CaptureKind, canvasSize: CGSize, pixelScale: Double, duration: Double? = nil) throws -> CaptureProject {
        var project = try makeProject(kind: kind, canvasSize: canvasSize, pixelScale: pixelScale, mediaExtension: url.pathExtension.lowercased())
        project.duration = duration
        try fileManager.copyItem(at: url, to: mediaURL(project))
        try save(project)
        return project
    }

    static func read(_ folder: URL) throws -> CaptureProject {
        try decoder.decode(CaptureProject.self, from: Data(contentsOf: folder.appendingPathComponent(manifestName)))
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
