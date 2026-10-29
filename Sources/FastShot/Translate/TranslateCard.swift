import AppKit
import FastShotCore
import NaturalLanguage
import Security
import SwiftUI
import Translation

enum TranslateEngine: String, CaseIterable, Identifiable {
    case offline, deepL
    var id: String { rawValue }
    var title: String { self == .offline ? "Çevrimdışı (bu Mac'te, ücretsiz)" : "DeepL (kendi anahtarınızla)" }
}

/// The DeepL key, in the login keychain, never in the preferences file.
enum DeepLKey {
    private static let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "FastShot DeepL", kSecAttrAccount: "DeepL API"]

    static var value: String? {
        get {
            var query = base
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            let key = String(data: data, encoding: .utf8)
            return key?.isEmpty == false ? key : nil
        }
        set {
            SecItemDelete(base as CFDictionary)
            guard let newValue, !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            var item = base
            item[kSecValueData] = Data(newValue.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
            item[kSecAttrLabel] = "FastShot çevirisi için DeepL API anahtarı"
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

@MainActor
enum Translator {
    static var usesDeepL: Bool { Preferences.shared.translateEngine == .deepL && DeepLKey.value != nil }
    static var engineTitle: String { usesDeepL ? "DeepL" : "Çevrimdışı" }

    /// The language of `text`: Apple's recogniser when it is sure, else FastShot's word count.
    static func guess(_ text: String) -> String? {
        let recogniser = NLLanguageRecognizer()
        recogniser.processString(text)
        if let (language, confidence) = recogniser.languageHypotheses(withMaximum: 1).first, confidence > 0.8 {
            let code = String(language.rawValue.prefix(2))
            if TranslationLanguages.all.contains(where: { $0.code == code }) { return code }
        }
        return TranslationLanguages.guess(text)
    }
}

@MainActor
final class TranslateModel: ObservableObject {
    @Published var original = ""
    @Published var translation = ""
    /// nil: detect.
    @Published var from: String?
    @Published var detected: String?
    @Published var to: String
    @Published var status = ""
    @Published var busy = false
    @Published var showOriginal = true
    @Published var engine = Translator.engineTitle
    @Published var configuration: TranslationSession.Configuration?

    /// The user picked the target in this card; a same-language result then is not switched for them.
    private var targetChosen = false
    private var loading = false
    private var request = 0
    private var pendingText = ""
    private var configuredPair: (String?, String)?
    private var typing: Task<Void, Never>?

    init() { to = Preferences.shared.translateTarget }

    func setSource(_ text: String) {
        loading = true
        original = text
        loading = false
        from = nil
        detected = nil
        targetChosen = false
        to = Preferences.shared.translateTarget
        // Text already in the target language goes the other way: Turkish to English, anything else to Turkish.
        if Translator.guess(text) == to { to = to == "tr" ? "en" : "tr" }
        showOriginal = true
        translate()
    }

    func originalChanged() {
        guard !loading else { return }
        typing?.cancel()
        typing = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.translate()
        }
    }

    func setFrom(_ code: String?) {
        from = code
        translate()
    }

    func setTarget(_ code: String, chosen: Bool) {
        to = code
        if chosen {
            targetChosen = true
            Preferences.shared.translateTarget = code
        }
    }

    func swap() {
        guard let source = from ?? detected ?? Translator.guess(original) else { return }
        loading = true
        if !translation.isEmpty { original = translation }
        loading = false
        from = to
        setTarget(source, chosen: true)
        translate()
    }

    func translate() {
        request += 1
        let id = request
        engine = Translator.engineTitle
        let text = TextReflow.join(original)
        guard !text.isEmpty else {
            translation = ""
            status = "Çevrilecek metni aşağıya yazın ya da yapıştırın."
            busy = false
            return
        }
        busy = true
        status = "Çevriliyor…"
        if Translator.usesDeepL, let key = DeepLKey.value {
            let (source, target) = (from, to)
            Task {
                do {
                    let result = try await DeepL.translate(text, from: source, to: target, key: key)
                    guard id == self.request else { return }
                    self.finish(result.text, source: result.detected ?? source)
                } catch {
                    guard id == self.request else { return }
                    self.fail(error.localizedDescription)
                }
            }
            return
        }
        // Apple's on-device engine runs through the card's translationTask; this hands it the request.
        let source = from ?? Translator.guess(text)
        if source == to, !targetChosen { setTarget(to == "tr" ? "en" : "tr", chosen: false) }
        pendingText = text
        if let pair = configuredPair, pair.0 == source, pair.1 == to, configuration != nil {
            configuration?.invalidate()
        } else {
            configuredPair = (source, to)
            configuration = TranslationSession.Configuration(source: source.map { Locale.Language(identifier: $0) }, target: Locale.Language(identifier: to))
        }
    }

    /// Runs inside SwiftUI's translationTask, which also offers to download a missing language.
    func run(_ session: TranslationSession) async {
        let id = request
        let text = pendingText
        guard !text.isEmpty else { return }
        do {
            let response = try await session.translate(text)
            guard id == request else { return }
            finish(response.targetText, source: response.sourceLanguage.languageCode?.identifier)
        } catch {
            guard id == request else { return }
            fail(from == to ? "Kaynak ve hedef dil aynı." :
                 "Bu dil çifti bu Mac'te çevrilemedi. Dil indirilmediyse yeniden deneyin ya da Ayarlar › Çeviri'den DeepL'i seçin.")
        }
    }

    private func finish(_ result: String, source: String?) {
        // Already in the target language (the engine knows better than the first guess): switch, unless the user chose it.
        if let source, source == to, !targetChosen {
            setTarget(to == "tr" ? "en" : "tr", chosen: false)
            translate()
            return
        }
        translation = result
        detected = from == nil ? source : nil
        status = source == to ? "Metin zaten \(TranslationLanguages.name(to))." : ""
        busy = false
    }

    private func fail(_ message: String) {
        translation = ""
        status = message
        busy = false
    }

    func copy(_ text: String, _ message: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Output.copy(text: text)
        status = message
    }
}

/// A floating card next to the pointer: the translation large and selectable, the recognised text below it
/// (editable, re-translates as it changes), language pills, copy buttons. Drag it anywhere; Esc closes it.
@MainActor
final class TranslateCard: NSObject, NSWindowDelegate {
    private static var shared: TranslateCard?
    private let panel: NSPanel
    let model = TranslateModel()

    /// Shows `text` (empty: an empty card to type or paste into) and translates it.
    static func show(_ text: String) {
        let card = shared ?? TranslateCard()
        let fresh = shared == nil
        shared = card
        card.model.setSource(text)
        NSApp.activate(ignoringOtherApps: true)
        if fresh { card.placeNearPointer() }
        card.panel.makeKeyAndOrderFront(nil)
    }

    private override init() {
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 480, height: 300), styleMask: [.titled, .closable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        let host = NSHostingController(rootView: TranslateCardView(model: model, close: { [weak self] in self?.panel.close() }))
        host.sizingOptions = .preferredContentSize
        panel.contentViewController = host
    }

    private func placeNearPointer() {
        panel.layoutIfNeeded()
        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size
        var origin = CGPoint(x: mouse.x + 16, y: mouse.y - 16 - size.height)
        if let visible = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(visible.minX, origin.x), visible.maxX - size.width)
            origin.y = min(max(visible.minY, origin.y), visible.maxY - size.height)
        }
        panel.setFrameOrigin(origin)
    }

    func windowDidResize(_ notification: Notification) {
        // Keep the whole card on screen as it grows.
        guard let visible = panel.screen?.visibleFrame else { return }
        var frame = panel.frame
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    func windowWillClose(_ notification: Notification) {
        if Self.shared === self { Self.shared = nil }
    }
}

private struct TranslateCardView: View {
    @ObservedObject var model: TranslateModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ZStack {
                if model.busy { ProgressView().progressViewStyle(.linear).tint(.accentColor) }
            }
            .frame(height: 3)
            ScrollView {
                Text(model.translation.isEmpty ? " " : model.translation)
                    .font(.system(size: 15.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 28, maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 12)
            Divider().padding(.horizontal, 16)
            Button { model.showOriginal.toggle() } label: {
                HStack(spacing: 6) {
                    Text("ORİJİNAL METİN").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Image(systemName: model.showOriginal ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
            if model.showOriginal {
                TextEditor(text: $model.original)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 44, maxHeight: 120)
                    .padding(.horizontal, 12).padding(.bottom, 8)
                    .onChange(of: model.original) { _, _ in model.originalChanged() }
            }
            HStack(spacing: 8) {
                Text(model.status).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 8)
                Button("Orijinali kopyala") { model.copy(model.original, "Metin kopyalandı") }
                Button { model.copy(model.translation, "Çeviri kopyalandı") } label: { Label("Kopyala", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
            .controlSize(.small)
            .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 12)
        }
        .frame(width: 460)
        .hudBackground(radius: 14)
        .padding(1)
        .translationTask(model.configuration) { session in await model.run(session) }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "translate").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor).padding(.trailing, 4)
            Menu {
                Button { model.setFrom(nil) } label: { check(model.from == nil, "Dili algıla") }
                Divider()
                ForEach(TranslationLanguages.all) { language in
                    Button { model.setFrom(language.code) } label: { check(model.from == language.code, language.name) }
                }
            } label: { pill(fromTitle) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            Menu {
                ForEach(TranslationLanguages.all) { language in
                    Button { model.setTarget(language.code, chosen: true); model.translate() } label: { check(model.to == language.code, language.name) }
                }
            } label: { pill(TranslationLanguages.name(model.to)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            IconButton(symbol: "arrow.left.arrow.right", help: "Dilleri değiştir", size: 24, action: model.swap)
            Spacer(minLength: 6)
            Text(model.engine)
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.1)))
            IconButton(symbol: "xmark", help: "Kapat (Esc)", size: 24, action: close)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.top, 10).padding(.bottom, 8)
    }

    private var fromTitle: String {
        if let from = model.from { return TranslationLanguages.name(from) }
        if let detected = model.detected { return "\(TranslationLanguages.name(detected)) (algılandı)" }
        return "Dili algıla"
    }

    private func pill(_ title: String) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.1)))
    }

    @ViewBuilder private func check(_ on: Bool, _ title: String) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}
