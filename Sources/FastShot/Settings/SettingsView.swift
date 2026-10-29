import AppKit
import FastShotCore
import ServiceManagement
import SwiftUI

enum SettingsTab: Hashable { case general, shortcuts, saving, video, convert, translate }

@MainActor
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var router = SettingsRouter.shared
    @ObservedObject var hotkeyStatus = HotkeyStatus.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hasPermission = Permissions.hasScreenRecording
    @State private var system = SystemScreenshotShortcuts.states()
    @State private var takenOver = SystemScreenshotShortcuts.isTakenOver
    @State private var working = false
    @ObservedObject private var updater = Updater.shared
    @State private var deepLSaved = DeepLKey.value != nil
    @State private var changingKey = false
    @State private var keyInput = ""
    @State private var keyState = ""
    @State private var testingKey = false

    var body: some View {
        TabView(selection: $router.tab) {
            general.tabItem { Label("Genel", systemImage: "gearshape") }.tag(SettingsTab.general)
            shortcuts.tabItem { Label("Kısayollar", systemImage: "keyboard") }.tag(SettingsTab.shortcuts)
            saving.tabItem { Label("Kaydetme", systemImage: "square.and.arrow.down") }.tag(SettingsTab.saving)
            video.tabItem { Label("Video", systemImage: "video") }.tag(SettingsTab.video)
            convert.tabItem { Label("Dosya çarkı", systemImage: "arrow.triangle.2.circlepath") }.tag(SettingsTab.convert)
            translation.tabItem { Label("Çeviri", systemImage: "translate") }.tag(SettingsTab.translate)
        }
        .padding(18)
        .frame(width: 600, height: 640)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshSystem() }
    }

    private func refreshSystem() {
        system = SystemScreenshotShortcuts.states()
        takenOver = SystemScreenshotShortcuts.isTakenOver
        hasPermission = Permissions.hasScreenRecording
    }

    private var general: some View {
        Form {
            Toggle("Oturum açıldığında başlat", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Toggle("Seçim yaparken büyüteci göster", isOn: $prefs.showMagnifier)
            Toggle("Ses efektlerini çal", isOn: $prefs.playSounds)
            Toggle("Simgeyi menü çubuğunda göster", isOn: $prefs.showMenuBarIcon)
            if !prefs.showMenuBarIcon {
                Text("FastShot çalışmaya devam eder. Ayarlara dönmek için FastShot'ı Uygulamalar'dan veya Spotlight'tan yeniden açın.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            LabeledContent("Ekran kaydı izni") {
                HStack {
                    Image(systemName: hasPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(hasPermission ? .green : .orange)
                    Text(hasPermission ? "Verildi" : "Gerekli")
                    if !hasPermission {
                        Button("Sistem Ayarlarını Aç") { Permissions.openScreenRecordingSettings() }
                        Button("Yeniden Başlat") { Permissions.relaunch() }
                    }
                }
            }
            LabeledContent("Geçmiş") {
                Button("Geçmiş klasörünü göster") { NSWorkspace.shared.open(ProjectLibrary.defaultRoot) }
            }
            Section("Güncellemeler") {
                LabeledContent("Sürüm") {
                    HStack {
                        Text(Updater.currentVersionString).monospacedDigit()
                        Text(updateStatus).foregroundStyle(.secondary)
                        if updater.status == .available {
                            Button("Güncelle") { Task { await Updater.shared.install() } }.buttonStyle(.borderedProminent)
                        } else {
                            Button("Şimdi denetle") { Task { await Updater.shared.check(userAsked: true) } }
                                .disabled(updater.status == .checking || updater.status == .downloading)
                        }
                    }
                }
                Toggle("Güncellemeleri otomatik denetle", isOn: $prefs.checkForUpdates)
                if !Updater.isInstalled {
                    Text("Bu kopya Uygulamalar klasörü dışında çalışıyor; kendini güncellemez.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Button("Sürüm notları") { NSWorkspace.shared.open(Updater.releasesPage) }.buttonStyle(.link)
            }
            Section {
                Button("FastShot'tan çık", role: .destructive) { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .onAppear { hasPermission = Permissions.hasScreenRecording }
    }

    private var updateStatus: String {
        switch updater.status {
        case .idle: return ""
        case .checking: return "Denetleniyor…"
        case .upToDate: return "Güncel"
        case .available: return "Yeni sürüm: \(updater.available?.versionString ?? "")"
        case .downloading: return "İndiriliyor…"
        case .failed: return updater.error ?? "Denetlenemedi"
        }
    }

    private var translation: some View {
        Form {
            Section {
                Picker("Motor", selection: $prefs.translateEngine) {
                    ForEach(TranslateEngine.allCases) { Text($0.title).tag($0) }
                }
                Picker("Hedef dil", selection: $prefs.translateTarget) {
                    ForEach(TranslationLanguages.all) { Text($0.name).tag($0.code) }
                }
            } footer: {
                Text("Seçim ekranında \"Metni tanı ve çevir\" (⇧⌘T), dosya çarkında Araçlar › Çevir ya da menü çubuğunda \"Çeviri…\". Ekrandan tanınan satırlar çeviriden önce paragraf olarak birleştirilir.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Çevrimdışı çeviri") {
                Text("Apple'ın çeviri motoru bu Mac'te çalışır: anahtar ve hesap gerekmez, metin Mac'ten çıkmaz. Bir dil ilk kez gerektiğinde macOS onu indirmeyi önerir; indirilen dilleri Sistem Ayarları › Genel › Dil ve Bölge › Çeviri Dilleri'nden yönetebilirsiniz.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Çeviri dillerini yönet") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
                }
            }
            Section("DeepL") {
                if deepLSaved && !changingKey {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                        Text(prefs.translateEngine == .deepL ? "API anahtarı girildi, DeepL kullanabilirsiniz." :
                                "API anahtarı girildi. DeepL'i kullanmak için yukarıda motoru \"DeepL\" yapın.").fontWeight(.semibold)
                        Spacer()
                        Button("Değiştir") { changingKey = true; keyState = "" }
                        Button("Sil") {
                            DeepLKey.value = nil
                            deepLSaved = false
                            if prefs.translateEngine == .deepL { prefs.translateEngine = .offline }
                            keyState = "Anahtar silindi; çeviriler bu Mac'teki motorla yapılır."
                        }
                    }
                } else {
                    LabeledContent("API anahtarı") {
                        HStack {
                            SecureField("", text: $keyInput).frame(minWidth: 220)
                            Button(testingKey ? "Deneniyor…" : "Kaydet ve dene") { saveDeepLKey() }
                                .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty || testingKey)
                            if changingKey { Button("Vazgeç") { changingKey = false; keyInput = ""; keyState = "" } }
                        }
                    }
                }
                if !keyState.isEmpty { Text(keyState).font(.system(size: 11)).foregroundStyle(.secondary) }
                Button("Ücretsiz DeepL anahtarı al") { NSWorkspace.shared.open(URL(string: "https://www.deepl.com/pro-api")!) }
                Text("Daha yüksek kalite için: DeepL'in ücretsiz planı (ayda 500.000 karakter) için deepl.com'dan bir anahtar alıp buraya yapıştırın. Anahtar yalnızca bu Mac'te, Anahtar Zinciri'nde saklanır; çeviriler sizin hesabınızdan gider. Anahtar yokken ya da motor \"Çevrimdışı\"yken bu Mac'teki motor kullanılır.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Tries the key with a tiny translation before keeping it.
    private func saveDeepLKey() {
        let key = keyInput
        testingKey = true
        keyState = "Anahtar deneniyor…"
        Task {
            do {
                _ = try await DeepL.translate("Merhaba", from: "tr", to: "en", key: key)
                DeepLKey.value = key
                deepLSaved = true
                changingKey = false
                keyInput = ""
                keyState = ""
                prefs.translateEngine = .deepL
            } catch {
                keyState = error.localizedDescription
            }
            testingKey = false
        }
    }

    private var shortcuts: some View {
        Form {
            Section {
                shortcutRow("Ekran görüntüsü", $prefs.screenshotHotkey)
                shortcutRow("Ekran görüntüsü (2. kısayol)", $prefs.screenshotHotkeyAlt)
                shortcutRow("Video kaydı başlat / bitir", $prefs.recordHotkey)
                shortcutRow("Video kaydı (2. kısayol)", $prefs.recordHotkeyAlt)
                shortcutRow("Finder'da seçili dosyaları dönüştür", $prefs.convertHotkey)
            } footer: {
                Text("Değiştirmek için kısayola tıklayıp yeni tuş kombinasyonuna basın (Esc: vazgeç). Print Screen yalnızca harici PC klavyelerinde bulunur ve macOS'ta F13 olarak gelir.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Mac'in ekran görüntüsü tuşları") {
                ForEach(SystemScreenshotShortcut.allCases) { shortcut in
                    let state = system[shortcut]
                    LabeledContent(shortcut.title) {
                        HStack(spacing: 8) {
                            Text(state?.combo?.displayString ?? "—").monospaced()
                            if SystemScreenshotShortcut.takeover.contains(shortcut), takenOver, state?.enabled == false {
                                Text("FastShot").font(.caption.weight(.semibold)).foregroundStyle(.green)
                            } else {
                                Text(state?.enabled == false ? "Kapalı" : "macOS").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if takenOver {
                    HStack {
                        Label("Seçili alan ve kayıt tuşları FastShot'ı açıyor.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Spacer()
                        Button("macOS'a geri ver") { restoreSystem() }.disabled(working)
                    }
                } else {
                    HStack {
                        Text(takeoverSummary).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("FastShot'a ver") { confirmTakeover() }.buttonStyle(.borderedProminent).disabled(working)
                    }
                }
                Button("Sistem Ayarları'nda Klavye Kısayolları'nı aç") { SystemScreenshotShortcuts.openKeyboardSettings() }
                    .buttonStyle(.link)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshSystem() }
    }

    private var convert: some View {
        Form {
            Section {
                Toggle("Dosya sürüklerken çarkı aç", isOn: $prefs.convertEnabled)
                Picker("Tuşlar", selection: $prefs.wheelKeyMode) {
                    ForEach(WheelKeyMode.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!prefs.convertEnabled)
                if prefs.wheelKeyMode == .single {
                    Picker("Çarkı açan tuş", selection: $prefs.singleWheelKey) {
                        ForEach(SingleWheelKey.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(!prefs.convertEnabled)
                } else {
                    ForEach(WheelMode.allCases) { mode in
                        Picker("\(mode.title) çarkı", selection: modifierBinding(for: mode)) {
                            ForEach(ConvertModifier.allCases) { Text($0.title).tag($0) }
                        }
                        .disabled(!prefs.convertEnabled)
                    }
                }
            } footer: {
                Text("Dosyaları sürüklerken bir tuşa bir kez basın; imlecin etrafında o çark açılır, seçeneğin üzerine bırakın. Aynı tuşa tekrar bastıkça sıradaki çarka geçilir; üstteki çubuğun üzerinde bir an beklemek de o çarkı açar. Bir çarkta seçenek yoksa sıradaki açılır. Tek tuş modunda sağ ⌥ (Mac'teki AltGr) yalnızca dosya sürüklerken çark açar, yazı yazmayı etkilemez. Sürüklemeden kullanmak için Finder'da dosyaları seçip \(prefs.convertHotkey?.displayString ?? "kısayola") basın ya da sağ tık (izleme dörtgeninde iki parmakla tıklama veya Control + tıklama) › Hizmetler › FastShot çarkı.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section {
                Picker("Oluşan dosyalar", selection: $prefs.convertDestination) {
                    ForEach(ConvertDestination.allCases) { Text($0.title).tag($0) }
                }
                if prefs.convertDestination == .custom { FolderRow(title: "Klasör", path: $prefs.convertFolder) }
                Toggle("Bitince Finder'da göster", isOn: $prefs.revealAfterConvert)
            } footer: {
                Text("Orijinal dosyalar hiçbir zaman değiştirilmez; sonuçlar yeni dosya olarak kaydedilir.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("\(prefs.convertModifier.glyph) Dönüştür") {
                ForEach([FileFamily.image, .video, .audio, .pdf, .document], id: \.self) { family in
                    LabeledContent(family.title) {
                        Text(FileConverter.targets(for: family).map(\.title).joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }
                if ExternalTools.webp == nil || ExternalTools.mp3 == nil {
                    Text("WebP ve MP3 çıktısı macOS'ta yerleşik değil. Homebrew ile `brew install webp lame` (ya da `ffmpeg`) kurarsanız FastShot bunları otomatik olarak çarka ekler.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Section("\(prefs.toolsModifier.glyph) Araçlar") {
                LabeledContent("Görüntü") { listText("Düzenle (çiz, yaz, bulanıklaştır) · Kırp · Arka plan · Sıkıştır · Meta veri sil · Metni kopyala") }
                LabeledContent("Video") { listText("Düzenle (çiz, kırp-süre) · Sıkıştır · Sesi kaldır · Meta veri sil") }
                LabeledContent("Ses · PDF") { listText("Sıkıştır · Meta veri sil · PDF birleştir (birden çok PDF)") }
            }
            Section("\(prefs.actionsModifier.glyph) İşlemler") {
                LabeledContent("Her dosya ve klasör") { listText("ZIP'le / ZIP'i aç · AirDrop · Panoya kopyala · Yolu kopyala · Ekrana sabitle (görüntü) · Terminal'de aç") }
            }
        }
        .formStyle(.grouped)
    }

    private func listText(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
    }

    /// Each wheel needs its own key; picking one that's taken swaps the two.
    private func modifierBinding(for mode: WheelMode) -> Binding<ConvertModifier> {
        Binding(get: { mode.modifier }, set: { newValue in
            let old = mode.modifier
            guard newValue != old else { return }
            if prefs.convertModifier == newValue { prefs.convertModifier = old }
            if prefs.toolsModifier == newValue { prefs.toolsModifier = old }
            if prefs.actionsModifier == newValue { prefs.actionsModifier = old }
            switch mode {
            case .convert: prefs.convertModifier = newValue
            case .tools: prefs.toolsModifier = newValue
            case .actions: prefs.actionsModifier = newValue
            }
        })
    }

    private var takeoverSummary: String {
        let copy = system[.copyArea]?.combo?.displayString ?? "⌃⇧⌘4"
        let save = system[.saveArea]?.combo?.displayString ?? "⇧⌘4"
        let options = system[.options]?.combo?.displayString ?? "⇧⌘5"
        return "\(copy) ve \(save) FastShot ekran görüntüsünü, \(options) FastShot video kaydını açsın."
    }

    @ViewBuilder
    private func shortcutRow(_ title: String, _ combo: Binding<KeyCombo?>) -> some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 3) {
                HotkeyRecorder(combo: combo)
                if let value = combo.wrappedValue {
                    if let owner = system.first(where: { $0.value.enabled && $0.value.combo == value })?.key {
                        Text("macOS bu tuşu kullanıyor (\(owner.title)); FastShot'a ulaşmaz.")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                    } else if hotkeyStatus.failed.contains(value) {
                        Text("Başka bir uygulama bu kısayolu kullanıyor.").font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private func confirmTakeover() {
        let alert = NSAlert()
        alert.messageText = "Ekran görüntüsü tuşları FastShot'a verilsin mi?"
        alert.informativeText = """
        macOS'un şu kısayolları kapatılıp FastShot'a atanacak:
        • \(SystemScreenshotShortcut.copyArea.title): \(system[.copyArea]?.combo?.displayString ?? "—")
        • \(SystemScreenshotShortcut.saveArea.title): \(system[.saveArea]?.combo?.displayString ?? "—")
        • \(SystemScreenshotShortcut.options.title): \(system[.options]?.combo?.displayString ?? "—")

        Tam ekran kısayolları macOS'ta kalır. "macOS'a geri ver" ile istediğiniz zaman eski hâline döndürebilirsiniz.
        """
        alert.addButton(withTitle: "FastShot'a Ver")
        alert.addButton(withTitle: "Vazgeç")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        working = true
        Task {
            do {
                let combos = try await SystemScreenshotShortcuts.takeOver()
                if let copy = combos[.copyArea] { prefs.screenshotHotkey = copy }
                if let save = combos[.saveArea] { prefs.screenshotHotkeyAlt = save }
                if let options = combos[.options] { prefs.recordHotkey = options }
            } catch {
                Output.showError(error, title: "Kısayollar devredilemedi")
            }
            working = false
            refreshSystem()
        }
    }

    private func restoreSystem() {
        working = true
        Task {
            await SystemScreenshotShortcuts.restore()
            prefs.resetShortcuts()
            working = false
            refreshSystem()
        }
    }

    private var saving: some View {
        Form {
            FolderRow(title: "Görüntü klasörü", path: $prefs.imageFolder)
            Picker("Biçim", selection: $prefs.imageFormat) {
                Text("PNG (kayıpsız)").tag(ImageFormat.png)
                Text("JPEG (küçük dosya)").tag(ImageFormat.jpeg)
            }
            if prefs.imageFormat == .jpeg {
                LabeledContent("JPEG kalitesi") {
                    Slider(value: $prefs.jpegQuality, in: 0.5...1) { Text("") } minimumValueLabel: { Text("%50") } maximumValueLabel: { Text("%100") }
                }
            }
            Toggle("Kaydederken panoya da kopyala", isOn: $prefs.copyWhenSaving)
            Text("Kopyaladığınız veya kaydettiğiniz her yakalama, çizimleri düzenlenebilir hâlde Geçmiş'te saklanır.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var video: some View {
        Form {
            FolderRow(title: "Video klasörü", path: $prefs.videoFolder)
            Picker("Kare hızı", selection: $prefs.framesPerSecond) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            Picker("Kodek", selection: $prefs.videoCodec) {
                ForEach(VideoCodec.allCases) { Text($0.title).tag($0) }
            }
            Picker("Geri sayım", selection: $prefs.countdown) {
                Text("Yok").tag(0)
                Text("3 saniye").tag(3)
                Text("5 saniye").tag(5)
            }
            Toggle("İmleci göster", isOn: $prefs.showCursor)
            Toggle("Sistem sesini kaydet", isOn: $prefs.recordSystemAudio)
            Toggle("Mikrofonu kaydet", isOn: $prefs.recordMicrophone)
            Toggle("Kayıttan sonra düzenleyiciyi aç", isOn: $prefs.openEditorAfterRecording)
            if !prefs.openEditorAfterRecording {
                Text("Kayıt doğrudan video klasörüne, kayıt sırasında çizdikleriniz de eklenerek kaydedilir.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct FolderRow: View {
    let title: String
    @Binding var path: String

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text((path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button("Seç…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.directoryURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                    if panel.runModal() == .OK, let url = panel.url { path = url.path }
                }
            }
        }
    }
}

/// Click, then press the new combination. Global shortcuts pause meanwhile so they can be re-recorded.
struct HotkeyRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Tuşlara basın…" : (combo?.displayString ?? "Yok"))
                    .frame(minWidth: 130)
                    .foregroundStyle(recording ? Color.accentColor : .primary)
            }
            if combo != nil, !recording {
                Button { combo = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Kısayolu kaldır")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                stop()
                return nil
            }
            if let recorded = KeyCombo(event: event) {
                combo = recorded
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        HotKeyCenter.shared.resume()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
