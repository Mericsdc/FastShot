import AppKit
import Combine
import FastShotCore

enum EditorTool: String, CaseIterable, Identifiable {
    case select, pen, line, arrow, rectangle, ellipse, marker, text, pixelate, step

    var id: String { rawValue }
    var kind: AnnotationKind? { self == .select ? nil : AnnotationKind(rawValue: rawValue) }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .pen: return "pencil.tip"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .marker: return "highlighter"
        case .text: return "textformat"
        case .pixelate: return "checkerboard.rectangle"
        case .step: return "1.circle"
        }
    }

    var title: String {
        switch self {
        case .select: return "Seç ve taşı"
        case .pen: return "Kalem"
        case .line: return "Çizgi"
        case .arrow: return "Ok"
        case .rectangle: return "Dikdörtgen"
        case .ellipse: return "Elips"
        case .marker: return "İşaretleyici"
        case .text: return "Metin"
        case .pixelate: return "Bulanıklaştır"
        case .step: return "Numara"
        }
    }

    var shortcut: Character {
        switch self {
        case .select: return "v"
        case .pen: return "p"
        case .line: return "l"
        case .arrow: return "a"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .marker: return "m"
        case .text: return "t"
        case .pixelate: return "b"
        case .step: return "n"
        }
    }

    var help: String { "\(title) (\(String(shortcut).uppercased()))" }

    /// Tools that make sense while recording: pixelation needs a frame to sample.
    static let live: [EditorTool] = [.pen, .arrow, .rectangle, .ellipse, .marker, .text, .step]
}

enum StyleChange { case color, size, filled }

/// The current tool and style, shared by a toolbar and its canvas. Choosing a
/// style while a mark is selected restyles that mark.
@MainActor
final class ToolState: ObservableObject {
    static let lineWidths: [Double] = [2, 4, 7, 12]
    static let fontSizes: [Double] = [14, 20, 28, 40]
    static let sizeNames = ["İnce", "Orta", "Kalın", "Çok kalın"]

    @Published var tool: EditorTool
    @Published var color: RGBAColor { didSet { styleDidChange(.color) } }
    @Published var size: Int { didSet { styleDidChange(.size) } }
    @Published var filled: Bool { didSet { styleDidChange(.filled) } }
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var hasSelection = false

    var onStyleChange: ((StyleChange) -> Void)?
    private var syncing = false

    init(tool: EditorTool = .select) {
        let prefs = Preferences.shared
        self.tool = tool
        self.color = prefs.lastColor
        self.size = min(max(prefs.lastSize, 0), Self.lineWidths.count - 1)
        self.filled = false
    }

    var lineWidth: Double { Self.lineWidths[size] }
    var fontSize: Double { Self.fontSizes[size] }

    /// Mirrors a selected mark's style without restyling it.
    func sync(with annotation: Annotation) {
        syncing = true
        defer { syncing = false }
        color = annotation.color
        filled = annotation.filled
        let reference = annotation.kind == .text || annotation.kind == .step ? Self.fontSizes : Self.lineWidths
        let value = annotation.kind == .text || annotation.kind == .step ? annotation.fontSize : annotation.lineWidth
        size = reference.indices.min { abs(reference[$0] - value) < abs(reference[$1] - value) } ?? 1
    }

    private func styleDidChange(_ change: StyleChange) {
        guard !syncing else { return }
        Preferences.shared.lastColor = color
        Preferences.shared.lastSize = size
        onStyleChange?(change)
    }
}
