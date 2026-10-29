import CoreGraphics
import Foundation

public struct TranslationLanguage: Hashable, Identifiable, Sendable {
    public let code: String
    public let name: String
    public var id: String { code }
}

/// The languages FastShot translates, with their Turkish names, and a guess of which one a text is in.
public enum TranslationLanguages {
    public static let all: [TranslationLanguage] = [
        ("tr", "Türkçe"), ("en", "İngilizce"), ("de", "Almanca"), ("fr", "Fransızca"), ("es", "İspanyolca"),
        ("it", "İtalyanca"), ("nl", "Felemenkçe"), ("pt", "Portekizce"), ("pl", "Lehçe"), ("cs", "Çekçe"),
        ("da", "Danca"), ("sv", "İsveççe"), ("fi", "Fince"), ("et", "Estonca"), ("ro", "Rumence"),
        ("bg", "Bulgarca"), ("el", "Yunanca"), ("hr", "Hırvatça"), ("sl", "Slovence"), ("ca", "Katalanca"),
        ("id", "Endonezce"), ("ms", "Malayca"), ("fa", "Farsça"), ("he", "İbranice"), ("hi", "Hintçe"),
        ("bn", "Bengalce"), ("gu", "Güceratça"), ("kn", "Kannada dili"), ("ml", "Malayalam dili"), ("te", "Telugu dili"),
        ("ru", "Rusça"), ("uk", "Ukraynaca"), ("ar", "Arapça"), ("ja", "Japonca"), ("ko", "Korece"), ("zh", "Çince"),
    ].map { TranslationLanguage(code: $0.0, name: $0.1) }

    public static func name(_ code: String) -> String { all.first { $0.code == code }?.name ?? code.uppercased() }

    static let commonWords: [String: Set<String>] = [
        "tr": ["ve", "bir", "bu", "için", "ile", "da", "de", "çok", "daha", "olarak", "gibi", "değil", "ama", "ne", "mi"],
        "en": ["the", "and", "is", "to", "of", "in", "that", "for", "it", "with", "you", "this", "are", "on", "be"],
        "de": ["der", "die", "das", "und", "ist", "nicht", "ein", "eine", "zu", "mit", "den", "sie", "ich", "auf", "für"],
        "fr": ["le", "la", "les", "et", "est", "des", "une", "un", "pour", "dans", "que", "pas", "vous", "sur", "du"],
        "es": ["el", "la", "los", "las", "y", "es", "que", "en", "un", "una", "por", "para", "con", "del", "se"],
        "it": ["il", "la", "che", "di", "e", "è", "un", "una", "per", "non", "con", "del", "della", "sono", "gli"],
        "nl": ["de", "het", "een", "en", "van", "is", "niet", "dat", "op", "voor", "met", "zijn", "ik", "je", "te"],
        "pt": ["o", "a", "os", "as", "e", "que", "não", "um", "uma", "para", "com", "do", "da", "em", "é"],
        "pl": ["i", "w", "nie", "się", "na", "jest", "to", "że", "z", "do", "jak", "ale", "co", "po", "tak"],
    ]

    /// The likely language of `text`, or nil when unsure: the script first, then the most frequent common words.
    /// Words with letters only Turkish uses count double for Turkish, but one stray "ı" (recognition reading English
    /// "side" as "sideı") does not outweigh a sentence of English.
    public static func guess(_ text: String) -> String? {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return nil }
        func share(_ range: ClosedRange<UInt32>) -> Double { Double(letters.filter { range.contains($0.value) }.count) / Double(letters.count) }
        let scripts: [(ClosedRange<UInt32>, String)] = [
            (0x0370...0x03FF, "el"), (0x0590...0x05FF, "he"), (0x0600...0x06FF, "ar"), (0x0900...0x097F, "hi"), (0x0980...0x09FF, "bn"),
            (0x0400...0x04FF, "ru"), (0x3040...0x30FF, "ja"), (0xAC00...0xD7AF, "ko"), (0x4E00...0x9FFF, "zh"),
        ]
        if let script = scripts.first(where: { share($0.0) > 0.3 }) { return script.1 }
        let words = text.lowercased(with: Locale(identifier: "tr")).split { " \n\r\t.,;:!?()\"'".contains($0) }.map(String.init)
        var scores = commonWords.mapValues { set in words.filter(set.contains).count }
        scores["tr", default: 0] += 2 * words.filter { $0.contains { "ğşı".contains($0) } }.count
        guard let best = scores.max(by: { $0.value < $1.value }), best.value > 0 else { return nil }
        return best.key
    }
}

/// Turns recognised lines back into paragraphs before translating. Text recognition returns the lines as they sit
/// on screen, so a sentence that wraps arrives in pieces, and a translator treats each piece as a sentence of its own.
public enum TextReflow {
    public struct Line: Sendable {
        public var text: String
        /// Position on the image, top-left origin.
        public var box: CGRect
        public init(text: String, box: CGRect) {
            self.text = text
            self.box = box
        }
    }

    static func isListItem(_ text: String) -> Bool {
        text.range(of: #"^\s*(?:[•·▪◦‣*–—-]|\d{1,3}[.)]|[a-zA-Z][.)])\s+"#, options: .regularExpression) != nil
    }

    /// A wide gap, a list item or a short line that ends a sentence starts a new paragraph; the rest join, and a word
    /// split with a hyphen at the end of a line is put back together.
    public static func join(_ lines: [Line]) -> String {
        let useful = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = useful.first else { return "" }
        let heights = useful.map(\.box.height).filter { $0 > 0 }.sorted()
        let lineHeight = heights.isEmpty ? 0 : heights[heights.count / 2]
        let right = useful.map(\.box.maxX).max() ?? 0
        var paragraphs = [first.text.trimmingCharacters(in: .whitespaces)]
        // A list item that wraps continues indented under its text; a line back at the item's left edge is new text.
        var itemLeft: CGFloat? = isListItem(first.text) ? first.box.minX : nil
        for index in 1..<useful.count {
            let previous = useful[index - 1], line = useful[index]
            let gap = line.box.minY - previous.box.maxY
            let shortLine = previous.box.maxX < right - max(lineHeight * 3, (right - previous.box.minX) * 0.2)
            let item = isListItem(line.text)
            var newParagraph = (lineHeight > 0 && gap > lineHeight * 0.6) || item || (endsSentence(previous.text) && shortLine)
            if let left = itemLeft, line.box.minX <= left + lineHeight * 0.5 { newParagraph = true }
            if lineHeight > 0, abs(line.box.minX - previous.box.minX) > lineHeight * 4 { newParagraph = true }
            if newParagraph {
                paragraphs.append(line.text.trimmingCharacters(in: .whitespaces))
                itemLeft = item ? line.box.minX : nil
            } else {
                append(&paragraphs[paragraphs.count - 1], line.text)
            }
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// Typed or pasted text: blank lines and list items separate paragraphs, other line breaks are wrapping.
    public static func join(_ text: String) -> String {
        var paragraphs: [String] = []
        var blank = true
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).isEmpty {
                blank = true
                continue
            }
            if blank || isListItem(raw) || paragraphs.isEmpty {
                paragraphs.append(raw.trimmingCharacters(in: .whitespaces))
            } else {
                append(&paragraphs[paragraphs.count - 1], raw)
            }
            blank = false
        }
        return paragraphs.joined(separator: "\n\n")
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".!?:;…\"”»)".contains(last)
    }

    static func append(_ paragraph: inout String, _ line: String) {
        let next = line.trimmingCharacters(in: .whitespaces)
        guard let firstChar = next.first else { return }
        // "çevi-" + "rilir" → "çevirilir"; a dash before a capital or a digit is a real dash.
        let chars = Array(paragraph)
        if chars.count > 1, chars[chars.count - 1] == "-", chars[chars.count - 2].isLetter, firstChar.isLowercase {
            paragraph.removeLast()
            paragraph += next
            return
        }
        paragraph += " " + next
    }
}

public enum DeepLError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// DeepL's API with the user's own key: free keys (ending in ":fx") use the free endpoint.
public enum DeepL {
    /// DeepL names English and Portuguese targets by their variant.
    static func target(_ code: String) -> String {
        switch code {
        case "en": return "EN-US"
        case "pt": return "PT-PT"
        case "zh": return "ZH-HANS"
        default: return code.uppercased()
        }
    }

    /// The translation and the source language DeepL detected (lower case).
    public static func translate(_ text: String, from: String?, to: String, key: String) async throws -> (text: String, detected: String?) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = trimmed.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
        var request = URLRequest(url: URL(string: "https://\(host)/v2/translate")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("DeepL-Auth-Key \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["text": [text], "target_lang": target(to), "preserve_formatting": true]
        if let from { body["source_lang"] = from.uppercased() }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw DeepLError.message("DeepL'e ulaşılamadı. İnternet bağlantınızı denetleyin.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            switch status {
            case 401, 403: throw DeepLError.message("DeepL anahtarı geçersiz. Ayarlar › Çeviri'den denetleyin.")
            case 456: throw DeepLError.message("DeepL'in bu ayki karakter hakkı doldu.")
            case 429: throw DeepLError.message("DeepL'e çok sık istek gönderildi; biraz sonra yeniden deneyin.")
            case 400: throw DeepLError.message("DeepL bu dil çiftini çeviremedi.")
            default: throw DeepLError.message("DeepL yanıt vermedi (\(status)).")
            }
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let first = (json?["translations"] as? [[String: Any]])?.first
        return (first?["text"] as? String ?? "", (first?["detected_source_language"] as? String)?.lowercased())
    }
}
