import FastShotCore
import SwiftUI

/// The three wheels, each opened by its own key while dragging.
enum WheelMode: Int, CaseIterable, Identifiable {
    case convert, tools, actions

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .convert: return "Dönüştür"
        case .tools: return "Araçlar"
        case .actions: return "İşlemler"
        }
    }

    /// The key shown on the mode bar: the wheel's own key, or the single key that steps through all of them.
    @MainActor var glyph: String {
        let prefs = Preferences.shared
        return prefs.wheelKeyMode == .single ? prefs.singleWheelKey.glyph : modifier.glyph
    }

    @MainActor var modifier: ConvertModifier {
        let prefs = Preferences.shared
        switch self {
        case .convert: return prefs.convertModifier
        case .tools: return prefs.toolsModifier
        case .actions: return prefs.actionsModifier
        }
    }
}

/// One segment of a wheel.
struct WheelItem: Identifiable {
    enum Kind {
        case convert(ConversionFormat)
        case tool(FileTool)
        case action(FileAction)
    }

    let id: String
    let title: String
    let detail: String?
    let symbol: String
    let tint: Color
    let kind: Kind

    static func items(for mode: WheelMode, files: [URL]) -> [WheelItem] {
        switch mode {
        case .convert:
            return FileConverter.targets(for: files).map {
                WheelItem(id: "convert.\($0.id)", title: $0.title, detail: $0.detail, symbol: $0.symbol, tint: $0.tint, kind: .convert($0))
            }
        case .tools:
            return FileTools.tools(for: files).map {
                WheelItem(id: "tool.\($0.rawValue)", title: $0.title, detail: $0.detail, symbol: $0.symbol, tint: $0.tint, kind: .tool($0))
            }
        case .actions:
            return FileTools.actions(for: files).map {
                WheelItem(id: "action.\($0.rawValue)", title: $0.title, detail: $0.detail, symbol: $0.symbol, tint: $0.tint, kind: .action($0))
            }
        }
    }
}

extension FileTool {
    var title: String {
        switch self {
        case .edit: return "Düzenle"
        case .crop: return "Kırp"
        case .background: return "Arka plan"
        case .compress: return "Sıkıştır"
        case .metadata: return "Meta veri"
        case .recognizeText: return "Metin"
        case .translate: return "Çevir"
        case .removeAudio: return "Sesi kaldır"
        case .mergePDF: return "Birleştir"
        }
    }

    var detail: String? {
        switch self {
        case .edit: return "Çiz · yaz"
        case .crop: return nil
        case .background: return "Paylaşıma hazır"
        case .compress: return "Küçült"
        case .metadata: return "Konumu sil"
        case .recognizeText: return "OCR · kopyala"
        case .translate: return "Metni çevir"
        case .removeAudio: return nil
        case .mergePDF: return "Tek PDF"
        }
    }

    var symbol: String {
        switch self {
        case .edit: return "pencil.and.outline"
        case .crop: return "crop"
        case .background: return "photo.artframe"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .metadata: return "location.slash"
        case .recognizeText: return "text.viewfinder"
        case .translate: return "translate"
        case .removeAudio: return "speaker.slash"
        case .mergePDF: return "doc.on.doc"
        }
    }

    var tint: Color {
        switch self {
        case .edit: return .blue
        case .crop: return .orange
        case .background: return .purple
        case .compress: return .green
        case .metadata: return .red
        case .recognizeText: return .teal
        case .translate: return .cyan
        case .removeAudio: return .pink
        case .mergePDF: return .indigo
        }
    }

    /// Wording for the result notice.
    var doneText: String {
        switch self {
        case .compress: return "sıkıştırıldı"
        case .metadata: return "meta verileri temizlendi"
        case .background: return "arka plan eklendi"
        case .removeAudio: return "sesi kaldırıldı"
        case .mergePDF: return "PDF'ler birleştirildi"
        case .crop: return "kırpıldı"
        case .edit, .recognizeText, .translate: return ""
        }
    }
}

extension FileAction {
    var title: String {
        switch self {
        case .zip: return "ZIP"
        case .unzip: return "ZIP'i aç"
        case .airDrop: return "AirDrop"
        case .copyToClipboard: return "Kopyala"
        case .copyPath: return "Yolu kopyala"
        case .pin: return "Sabitle"
        case .terminal: return "Terminal"
        }
    }

    var detail: String? {
        switch self {
        case .zip: return "Arşivle"
        case .unzip: return "Çıkar"
        case .copyToClipboard: return "Panoya"
        case .pin: return "Ekrana"
        case .terminal: return "Klasörde aç"
        case .airDrop, .copyPath: return nil
        }
    }

    var symbol: String {
        switch self {
        case .zip: return "doc.zipper"
        case .unzip: return "archivebox"
        case .airDrop: return "dot.radiowaves.left.and.right"
        case .copyToClipboard: return "doc.on.clipboard"
        case .copyPath: return "link"
        case .pin: return "pin"
        case .terminal: return "terminal"
        }
    }

    var tint: Color {
        switch self {
        case .zip, .unzip: return .brown
        case .airDrop: return .blue
        case .copyToClipboard: return .teal
        case .copyPath: return .indigo
        case .pin: return .orange
        case .terminal: return .gray
        }
    }
}
