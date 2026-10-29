import AppKit
import Combine
import FastShotCore

enum VideoCodec: String, CaseIterable, Identifiable {
    case h264, hevc
    var id: String { rawValue }
    var title: String { self == .h264 ? "H.264 (en uyumlu)" : "HEVC (daha küçük dosya)" }
}

/// Key that opens the conversion wheel while files are being dragged.
enum ConvertModifier: String, CaseIterable, Identifiable {
    case shift, option, control, command
    var id: String { rawValue }
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .option: return .option
        case .control: return .control
        case .command: return .command
        }
    }
    var title: String {
        switch self {
        case .shift: return "⇧ Shift"
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        case .command: return "⌘ Command"
        }
    }
}

enum ConvertDestination: String, CaseIterable, Identifiable {
    case beside, downloads, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .beside: return "Kaynak dosyanın yanına"
        case .downloads: return "İndirilenler klasörüne"
        case .custom: return "Seçtiğim klasöre"
        }
    }
}

/// User settings, persisted in UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    @Published var screenshotHotkey: KeyCombo? { didSet { storeCombo(screenshotHotkey, "hotkey.screenshot") } }
    @Published var screenshotHotkeyAlt: KeyCombo? { didSet { storeCombo(screenshotHotkeyAlt, "hotkey.screenshotAlt") } }
    @Published var recordHotkey: KeyCombo? { didSet { storeCombo(recordHotkey, "hotkey.record") } }
    @Published var recordHotkeyAlt: KeyCombo? { didSet { storeCombo(recordHotkeyAlt, "hotkey.recordAlt") } }
    /// Opens the conversion wheel for the files selected in Finder; no dragging or right-click needed.
    @Published var convertHotkey: KeyCombo? { didSet { storeCombo(convertHotkey, "hotkey.convert") } }

    @Published var imageFolder: String { didSet { defaults.set(imageFolder, forKey: "folder.images") } }
    @Published var videoFolder: String { didSet { defaults.set(videoFolder, forKey: "folder.videos") } }
    @Published var imageFormat: ImageFormat { didSet { defaults.set(imageFormat.rawValue, forKey: "image.format") } }
    @Published var jpegQuality: Double { didSet { defaults.set(jpegQuality, forKey: "image.jpegQuality") } }
    @Published var copyWhenSaving: Bool { didSet { defaults.set(copyWhenSaving, forKey: "image.copyWhenSaving") } }
    @Published var showMagnifier: Bool { didSet { defaults.set(showMagnifier, forKey: "capture.magnifier") } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "general.sounds") } }

    @Published var framesPerSecond: Int { didSet { defaults.set(framesPerSecond, forKey: "video.fps") } }
    @Published var showCursor: Bool { didSet { defaults.set(showCursor, forKey: "video.cursor") } }
    @Published var recordSystemAudio: Bool { didSet { defaults.set(recordSystemAudio, forKey: "video.systemAudio") } }
    @Published var recordMicrophone: Bool { didSet { defaults.set(recordMicrophone, forKey: "video.microphone") } }
    @Published var videoCodec: VideoCodec { didSet { defaults.set(videoCodec.rawValue, forKey: "video.codec") } }
    @Published var countdown: Int { didSet { defaults.set(countdown, forKey: "video.countdown") } }
    @Published var openEditorAfterRecording: Bool { didSet { defaults.set(openEditorAfterRecording, forKey: "video.openEditor") } }
    @Published var convertEnabled: Bool { didSet { defaults.set(convertEnabled, forKey: "convert.enabled") } }
    @Published var convertModifier: ConvertModifier { didSet { defaults.set(convertModifier.rawValue, forKey: "convert.modifier") } }
    @Published var toolsModifier: ConvertModifier { didSet { defaults.set(toolsModifier.rawValue, forKey: "convert.toolsModifier") } }
    @Published var actionsModifier: ConvertModifier { didSet { defaults.set(actionsModifier.rawValue, forKey: "convert.actionsModifier") } }
    @Published var convertDestination: ConvertDestination { didSet { defaults.set(convertDestination.rawValue, forKey: "convert.destination") } }
    @Published var convertFolder: String { didSet { defaults.set(convertFolder, forKey: "convert.folder") } }
    @Published var revealAfterConvert: Bool { didSet { defaults.set(revealAfterConvert, forKey: "convert.reveal") } }

    /// Seconds a mark drawn in the video editor stays visible; 0 means until the end.
    @Published var annotationLength: Double { didSet { defaults.set(annotationLength, forKey: "video.annotationLength") } }

    var lastColor: RGBAColor {
        get { defaults.string(forKey: "style.color").flatMap(RGBAColor.init(hex:)) ?? .red }
        set { defaults.set(newValue.hex, forKey: "style.color") }
    }

    var lastSize: Int {
        get { defaults.object(forKey: "style.size") as? Int ?? 1 }
        set { defaults.set(newValue, forKey: "style.size") }
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: "general.onboarded") }
        set { defaults.set(newValue, forKey: "general.onboarded") }
    }

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Mac keyboards have no Print Screen key, so the ⌘ shortcuts come first;
        // Print Screen (F13) still works on external PC keyboards.
        screenshotHotkey = Self.loadCombo("hotkey.screenshot", fallback: .commandShift2)
        screenshotHotkeyAlt = Self.loadCombo("hotkey.screenshotAlt", fallback: .printScreen)
        recordHotkey = Self.loadCombo("hotkey.record", fallback: .commandShift7)
        recordHotkeyAlt = Self.loadCombo("hotkey.recordAlt", fallback: .shiftPrintScreen)
        convertHotkey = Self.loadCombo("hotkey.convert", fallback: .controlShiftD)
        imageFolder = defaults.string(forKey: "folder.images") ?? home.appendingPathComponent("Pictures/FastShot").path
        videoFolder = defaults.string(forKey: "folder.videos") ?? home.appendingPathComponent("Movies/FastShot").path
        imageFormat = ImageFormat(rawValue: defaults.string(forKey: "image.format") ?? "") ?? .png
        jpegQuality = defaults.object(forKey: "image.jpegQuality") as? Double ?? 0.9
        copyWhenSaving = defaults.object(forKey: "image.copyWhenSaving") as? Bool ?? false
        showMagnifier = defaults.object(forKey: "capture.magnifier") as? Bool ?? true
        playSounds = defaults.object(forKey: "general.sounds") as? Bool ?? true
        framesPerSecond = defaults.object(forKey: "video.fps") as? Int ?? 60
        showCursor = defaults.object(forKey: "video.cursor") as? Bool ?? true
        recordSystemAudio = defaults.object(forKey: "video.systemAudio") as? Bool ?? false
        recordMicrophone = defaults.object(forKey: "video.microphone") as? Bool ?? false
        videoCodec = VideoCodec(rawValue: defaults.string(forKey: "video.codec") ?? "") ?? .h264
        countdown = defaults.object(forKey: "video.countdown") as? Int ?? 0
        openEditorAfterRecording = defaults.object(forKey: "video.openEditor") as? Bool ?? true
        annotationLength = defaults.object(forKey: "video.annotationLength") as? Double ?? 3
        convertEnabled = defaults.object(forKey: "convert.enabled") as? Bool ?? true
        convertModifier = ConvertModifier(rawValue: defaults.string(forKey: "convert.modifier") ?? "") ?? .shift
        toolsModifier = ConvertModifier(rawValue: defaults.string(forKey: "convert.toolsModifier") ?? "") ?? .command
        actionsModifier = ConvertModifier(rawValue: defaults.string(forKey: "convert.actionsModifier") ?? "") ?? .control
        convertDestination = ConvertDestination(rawValue: defaults.string(forKey: "convert.destination") ?? "") ?? .beside
        convertFolder = defaults.string(forKey: "convert.folder") ?? home.appendingPathComponent("Downloads").path
        revealAfterConvert = defaults.object(forKey: "convert.reveal") as? Bool ?? false
    }

    func resetShortcuts() {
        screenshotHotkey = .commandShift2
        screenshotHotkeyAlt = .printScreen
        recordHotkey = .commandShift7
        recordHotkeyAlt = .shiftPrintScreen
    }

    var imageFolderURL: URL { URL(fileURLWithPath: (imageFolder as NSString).expandingTildeInPath, isDirectory: true) }
    var videoFolderURL: URL { URL(fileURLWithPath: (videoFolder as NSString).expandingTildeInPath, isDirectory: true) }

    /// Absent key: use the default. Empty data: the user cleared the shortcut.
    private static func loadCombo(_ key: String, fallback: KeyCombo) -> KeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return fallback }
        return data.isEmpty ? nil : try? JSONDecoder().decode(KeyCombo.self, from: data)
    }

    private func storeCombo(_ combo: KeyCombo?, _ key: String) {
        let data = combo.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        defaults.set(data, forKey: key)
    }
}
