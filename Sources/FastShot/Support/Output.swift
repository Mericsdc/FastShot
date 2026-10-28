import AppKit
import FastShotCore
import UniformTypeIdentifiers

extension Notification.Name {
    static let libraryDidChange = Notification.Name("FastShotLibraryDidChange")
}

/// Naming, saving, clipboard and feedback sounds.
@MainActor
enum Output {
    enum Sound: String {
        case shutter = "Screen Capture.aif"
        case recordStart = "begin_record.caf"
        case recordStop = "end_record.caf"
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "yyyy-MM-dd 'saat' HH.mm.ss"
        return formatter
    }()

    static func baseName(_ date: Date = Date()) -> String { "FastShot \(stamp.string(from: date))" }

    static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return url
    }

    static func copy(image: CGImage, pointScale: Double) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let size = CGSize(width: CGFloat(image.width) / pointScale, height: CGFloat(image.height) / pointScale)
        let nsImage = NSImage(cgImage: image, size: size)
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        if let png = ImageExporter.encode(image, format: .png, pointScale: pointScale) { pasteboard.setData(png, forType: .png) }
        if let tiff = nsImage.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
    }

    static func copy(fileURL: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
    }

    static func copy(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func write(image: CGImage, to url: URL, format: ImageFormat, pointScale: Double) throws {
        guard let data = ImageExporter.encode(image, format: format, quality: Preferences.shared.jpegQuality, pointScale: pointScale) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Saves to the default folder without asking.
    static func quickSave(image: CGImage, pointScale: Double) throws -> URL {
        let prefs = Preferences.shared
        let url = uniqueURL(in: prefs.imageFolderURL, base: baseName(), ext: prefs.imageFormat.fileExtension)
        try write(image: image, to: url, format: prefs.imageFormat, pointScale: pointScale)
        return url
    }

    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    static func play(_ sound: Sound) {
        guard Preferences.shared.playSounds else { return }
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/" + sound.rawValue
        (NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Tink"))?.play()
    }

    static func showError(_ error: Error, title: String = "İşlem tamamlanamadı") {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// A save dialog with a format picker that keeps the file extension in step.
@MainActor
enum SavePanel {
    struct Format {
        let title: String
        let fileExtension: String
        let type: UTType
    }

    @MainActor
    private final class Switcher: NSObject {
        let panel: NSSavePanel
        let formats: [Format]
        init(panel: NSSavePanel, formats: [Format]) {
            self.panel = panel
            self.formats = formats
        }

        @objc func changed(_ sender: NSPopUpButton) {
            let format = formats[sender.indexOfSelectedItem]
            panel.allowedContentTypes = [format.type]
            let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
        }
    }

    static func run(name: String, directory: URL, formats: [Format], initial: Int = 0) -> (url: URL, format: Int)? {
        let panel = NSSavePanel()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        panel.directoryURL = directory
        panel.nameFieldStringValue = "\(name).\(formats[initial].fileExtension)"
        panel.allowedContentTypes = [formats[initial].type]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let switcher = Switcher(panel: panel, formats: formats)
        if formats.count > 1 {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: formats.map(\.title))
            popup.selectItem(at: initial)
            popup.target = switcher
            popup.action = #selector(Switcher.changed(_:))
            let label = NSTextField(labelWithString: "Biçim:")
            let stack = NSStackView(views: [label, popup])
            stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
            panel.accessoryView = stack
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        withExtendedLifetime(switcher) {}
        guard response == .OK, let url = panel.url else { return nil }
        let index = formats.firstIndex { $0.fileExtension == url.pathExtension.lowercased() } ?? initial
        return (url, index)
    }

    static let imageFormats = [Format(title: "PNG", fileExtension: "png", type: .png), Format(title: "JPEG", fileExtension: "jpg", type: .jpeg)]
    static let videoFormats = [Format(title: "MP4 video", fileExtension: "mp4", type: .mpeg4Movie),
                               Format(title: "QuickTime (MOV)", fileExtension: "mov", type: .quickTimeMovie),
                               Format(title: "Animasyonlu GIF", fileExtension: "gif", type: .gif)]
}
