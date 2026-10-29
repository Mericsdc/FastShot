import AVFoundation
import AppKit
import Carbon.HIToolbox
import Combine
import FastShotCore
import SwiftUI
import UniformTypeIdentifiers

/// Menu bar app: owns the shortcuts, the status item and every window.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static private(set) var shared: AppController!

    let library = ProjectLibrary()
    private let prefs = Preferences.shared
    private var statusItem: NSStatusItem!
    private var statusMenu = NSMenu()
    private var screenshotItem: NSMenuItem!
    private var recordItem: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var lastCaptureItem: NSMenuItem!
    private var capture: CaptureSession?
    private var recording: RecordingSession?
    private var editors: [EditorWindowController] = []
    private var settingsWindow: NSWindow?
    private var libraryWindow: NSWindow?
    private var libraryModel: LibraryModel?
    private var observers = Set<AnyCancellable>()
    private var startingCapture = false
    private var pendingURLs: [URL] = []
    private var launched = false

    override init() {
        super.init()
        AppController.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildStatusItem()
        HotKeyCenter.shared.reregister = { [weak self] in self?.registerHotkeys() }
        registerHotkeys()
        DragMonitor.shared.onTrigger = { urls, point, mode in ConversionWheel.shared.show(files: urls, at: point, interactive: false, mode: mode) }
        DragMonitor.shared.onSwitch = { mode in ConversionWheel.shared.switchMode(mode) }
        DragMonitor.shared.onDragEnded = { ConversionWheel.shared.dragEnded() }
        DragMonitor.shared.start()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        prefs.objectWillChange
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.registerHotkeys()
                self?.updateMenuShortcuts()
            }
            .store(in: &observers)
        launched = true
        if !prefs.hasCompletedOnboarding {
            prefs.hasCompletedOnboarding = true
            showWelcome()
        }
        pendingURLs.forEach(open)
        pendingURLs.removeAll()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else { pendingURLs += urls; return }
        urls.forEach(open)
    }

    /// Opening FastShot again (Finder, Spotlight, Launchpad) shows its settings: the menu bar
    /// icon can hide behind a MacBook's camera notch, so this is the dependable way in.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openSettings(tab: .shortcuts) }
        return true
    }

    // MARK: Shortcuts

    private func registerHotkeys() {
        let center = HotKeyCenter.shared
        guard !center.isSuspended else { return }
        center.unregisterAll()
        let bindings: [(KeyCombo?, () -> Void)] = [
            (prefs.screenshotHotkey, { [weak self] in self?.takeScreenshot() }),
            (prefs.screenshotHotkeyAlt, { [weak self] in self?.takeScreenshot() }),
            (prefs.recordHotkey, { [weak self] in self?.recordVideo() }),
            (prefs.recordHotkeyAlt, { [weak self] in self?.recordVideo() }),
            (prefs.convertHotkey, { ConversionCenter.shared.convertFinderSelection() }),
        ]
        var failed = Set<KeyCombo>()
        for (combo, action) in bindings {
            guard let combo else { continue }
            if !center.register(combo, handler: action) { failed.insert(combo) }
        }
        HotkeyStatus.shared.failed = failed
    }

    // MARK: Capture

    @objc func takeScreenshot() { startCapture(.screenshot) }

    @objc func recordVideo() {
        if let recording {
            recording.stop()
            return
        }
        startCapture(.video)
    }

    private func startCapture(_ mode: CaptureSession.Mode) {
        guard capture == nil else { return }
        if mode == .video, recording != nil { return }
        guard !startingCapture, Permissions.ensureScreenRecording() else { return }
        startingCapture = true
        let frames = ScreenGrabber.windowFrames()
        Task { [weak self] in
            guard let self else { return }
            defer { self.startingCapture = false }
            do {
                let shots = try await ScreenGrabber.captureAllScreens()
                guard !shots.isEmpty else { return }
                let session = CaptureSession(mode: mode, shots: shots, windowFrames: frames)
                session.onFinish = { [weak self] finished in
                    if self?.capture === finished { self?.capture = nil }
                    HotKeyCenter.shared.resume()
                }
                session.onRecord = { [weak self] request in self?.startRecording(request) }
                session.onOpenEditor = { [weak self] project in self?.openEditor(project) }
                self.capture = session
                // The overlay's own ⌘-commands (⌘C, ⌘S, ⌘P…) must not be swallowed by global shortcuts.
                HotKeyCenter.shared.suspend()
                session.begin()
            } catch {
                Output.showError(error, title: "Ekran görüntüsü alınamadı")
            }
        }
    }

    private func startRecording(_ request: RecordRequest) {
        guard recording == nil else { return }
        let session = RecordingSession(request: request)
        recording = session
        setRecordingStatus(true)
        session.onTick = { [weak self] seconds in self?.statusItem.button?.title = " " + RecordingHUD.format(seconds) }
        session.onFinish = { [weak self] project in
            guard let self else { return }
            self.recording = nil
            self.setRecordingStatus(false)
            guard let project else { return }
            if self.prefs.openEditorAfterRecording {
                self.openEditor(project)
            } else {
                self.exportRecording(project)
            }
        }
        Task { await session.start() }
    }

    /// Without the editor, the recording goes straight to the video folder with its live marks burned in.
    private func exportRecording(_ project: CaptureProject) {
        let url = Output.uniqueURL(in: prefs.videoFolderURL, base: Output.baseName(project.createdAt), ext: "mp4")
        let request = VideoExportRequest(source: library.mediaURL(project), canvasSize: project.canvasSize, annotations: project.annotations,
                                         trim: nil, preferHEVC: prefs.videoCodec == .hevc)
        Task {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await VideoExporter.export(request, to: url, format: .mp4) { _ in }
                Toast.show("Video kaydedildi", symbol: "video.fill", detail: url.lastPathComponent, actionTitle: "Göster") { Output.reveal(url) }
            } catch {
                Output.showError(error, title: "Video kaydedilemedi")
            }
        }
    }

    @objc private func stopRecordingFromStatusItem() { recording?.stop() }

    private func setRecordingStatus(_ active: Bool) {
        guard let button = statusItem.button else { return }
        if active {
            statusItem.menu = nil
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Kaydı bitir")
            button.contentTintColor = .systemRed
            button.title = " 00:00"
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(stopRecordingFromStatusItem)
            button.toolTip = "Kaydı bitirmek için tıklayın"
        } else {
            button.image = Self.menuBarIcon
            button.contentTintColor = nil
            button.title = ""
            button.action = nil
            button.toolTip = "FastShot"
            statusItem.menu = statusMenu
        }
    }

    // MARK: Editors and windows

    func openEditor(_ project: CaptureProject) {
        if let existing = editors.first(where: { $0.project.id == project.id }) {
            existing.present()
            return
        }
        let editor: EditorWindowController?
        switch project.kind {
        case .image: editor = ImageEditorController(project: project, library: library)
        case .video: editor = VideoEditorController(project: project, library: library)
        }
        guard let editor else {
            Output.showError(CocoaError(.fileReadCorruptFile), title: "Yakalama açılamadı")
            return
        }
        editor.onClose = { [weak self] closed in
            self?.editors.removeAll { $0 === closed }
            self?.updateActivationPolicy()
        }
        editors.append(editor)
        updateActivationPolicy()
        editor.present()
    }

    private func updateActivationPolicy() {
        DispatchQueue.main.async {
            let visible = !self.editors.isEmpty || self.settingsWindow?.isVisible == true || self.libraryWindow?.isVisible == true
            NSApp.setActivationPolicy(visible ? .regular : .accessory)
        }
    }

    @objc func showSettings() { openSettings(tab: nil) }

    func openSettings(tab: SettingsTab?) {
        if let tab { SettingsRouter.shared.tab = tab }
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "FastShot Ayarları"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            observeClose(window)
            settingsWindow = window
        }
        settingsWindow?.center()
        present(settingsWindow)
    }

    @objc func showLibrary() {
        if libraryWindow == nil {
            let model = LibraryModel(library: library)
            model.open = { [weak self] project in self?.openEditor(project) }
            libraryModel = model
            let window = NSWindow(contentViewController: NSHostingController(rootView: LibraryView(model: model)))
            window.title = "FastShot Geçmişi"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(CGSize(width: 860, height: 600))
            window.isReleasedWhenClosed = false
            window.center()
            observeClose(window)
            libraryWindow = window
        }
        libraryModel?.reload()
        present(libraryWindow)
    }

    private func present(_ window: NSWindow?) {
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func observeClose(_ window: NSWindow) {
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
            .sink { [weak self] _ in self?.updateActivationPolicy() }
            .store(in: &observers)
    }

    @objc func chooseFilesToConvert() { ConversionCenter.shared.chooseFiles() }

    /// Finder › Services › "FastShot çarkı": opens the wheel for the selected files.
    @objc func convertFilesService(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        ConversionWheel.shared.show(files: urls, at: NSEvent.mouseLocation, interactive: true)
    }

    @objc func editLastCapture() {
        guard let project = library.allProjects().first else { return }
        openEditor(project)
    }

    @objc func openFile() {
        let panel = NSOpenPanel()
        let packageType = UTType(filenameExtension: ProjectLibrary.packageExtension, conformingTo: .package) ?? .package
        panel.allowedContentTypes = [.image, .movie, packageType]
        panel.allowsMultipleSelection = false
        panel.message = "Düzenlemek için bir görüntü, video veya FastShot projesi seçin"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    /// Opens files in FastShot's own editors (drawing, text, blur, trimming).
    func openInEditor(_ urls: [URL]) {
        urls.prefix(10).forEach(open)
    }

    private func open(_ url: URL) {
        Task {
            do {
                let project = try await importFile(url)
                NotificationCenter.default.post(name: .libraryDidChange, object: nil)
                openEditor(project)
            } catch {
                Output.showError(error, title: "Dosya açılamadı")
            }
        }
    }

    private func importFile(_ url: URL) async throws -> CaptureProject {
        if url.pathExtension.lowercased() == ProjectLibrary.packageExtension { return try library.importPackage(at: url) }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .movie) {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
            let natural = try await track.load(.naturalSize)
            let duration = try await asset.load(.duration).seconds
            let scale: Double = natural.width > 2400 ? 2 : 1
            let project = try library.importMedia(at: url, kind: .video, canvasSize: CGSize(width: natural.width / scale, height: natural.height / scale),
                                                  pixelScale: scale, duration: duration)
            if let frame = try? await VideoExporter.frame(of: url, at: min(0.5, duration / 2), maxSide: 800) { library.writeThumbnail(frame, for: project) }
            return project
        }
        guard let image = ImageExporter.load(url) else { throw CocoaError(.fileReadCorruptFile) }
        let scale = ImageExporter.pointScale(of: url) ?? (image.width > 3000 ? 2 : 1)
        let project = try library.importMedia(at: url, kind: .image,
                                              canvasSize: CGSize(width: Double(image.width) / scale, height: Double(image.height) / scale), pixelScale: scale)
        library.writeThumbnail(image, for: project)
        return project
    }

    // MARK: Menus

    static var menuBarIcon: NSImage? {
        let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "FastShot")
        image?.isTemplate = true
        return image
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.menuBarIcon
        statusItem.button?.toolTip = "FastShot"

        screenshotItem = statusMenu.addItem(withTitle: "Ekran görüntüsü al", action: #selector(takeScreenshot), keyEquivalent: "")
        recordItem = statusMenu.addItem(withTitle: "Alanı videoya kaydet", action: #selector(recordVideo), keyEquivalent: "")
        statusMenu.addItem(.separator())
        lastCaptureItem = statusMenu.addItem(withTitle: "Son yakalamayı düzenle", action: #selector(editLastCapture), keyEquivalent: "")
        statusMenu.addItem(withTitle: "Geçmiş…", action: #selector(showLibrary), keyEquivalent: "")
        statusMenu.addItem(withTitle: "Görüntü veya video aç…", action: #selector(openFile), keyEquivalent: "")
        statusMenu.addItem(withTitle: "Dosyaları dönüştür…", action: #selector(chooseFilesToConvert), keyEquivalent: "")
        statusMenu.addItem(.separator())
        permissionItem = statusMenu.addItem(withTitle: "Ekran kaydı iznini ver…", action: #selector(requestPermission), keyEquivalent: "")
        statusMenu.addItem(withTitle: "Ayarlar…", action: #selector(showSettings), keyEquivalent: ",")
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "FastShot'tan çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in statusMenu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        screenshotItem.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
        recordItem.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        statusMenu.delegate = self
        statusItem.menu = statusMenu
        updateMenuShortcuts()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        permissionItem.isHidden = Permissions.hasScreenRecording
        lastCaptureItem.isEnabled = library.allProjects().first != nil
    }

    @objc private func requestPermission() { _ = Permissions.ensureScreenRecording() }

    private func updateMenuShortcuts() {
        for (item, combo) in [(screenshotItem, prefs.screenshotHotkey ?? prefs.screenshotHotkeyAlt), (recordItem, prefs.recordHotkey ?? prefs.recordHotkeyAlt)] {
            guard let item else { continue }
            let shortcut = Self.menuShortcut(combo)
            item.keyEquivalent = shortcut.key
            item.keyEquivalentModifierMask = shortcut.modifiers
        }
    }

    static func menuShortcut(_ combo: KeyCombo?) -> (key: String, modifiers: NSEvent.ModifierFlags) {
        guard let combo else { return ("", []) }
        var modifiers: NSEvent.ModifierFlags = []
        if combo.carbonModifiers & UInt32(cmdKey) != 0 { modifiers.insert(.command) }
        if combo.carbonModifiers & UInt32(shiftKey) != 0 { modifiers.insert(.shift) }
        if combo.carbonModifiers & UInt32(optionKey) != 0 { modifiers.insert(.option) }
        if combo.carbonModifiers & UInt32(controlKey) != 0 { modifiers.insert(.control) }
        let functionKeys: [Int: Int] = [
            kVK_F1: NSF1FunctionKey, kVK_F2: NSF2FunctionKey, kVK_F3: NSF3FunctionKey, kVK_F4: NSF4FunctionKey, kVK_F5: NSF5FunctionKey,
            kVK_F6: NSF6FunctionKey, kVK_F7: NSF7FunctionKey, kVK_F8: NSF8FunctionKey, kVK_F9: NSF9FunctionKey, kVK_F10: NSF10FunctionKey,
            kVK_F11: NSF11FunctionKey, kVK_F12: NSF12FunctionKey, kVK_F13: NSF13FunctionKey, kVK_F14: NSF14FunctionKey, kVK_F15: NSF15FunctionKey,
            kVK_F16: NSF16FunctionKey, kVK_F17: NSF17FunctionKey, kVK_F18: NSF18FunctionKey, kVK_F19: NSF19FunctionKey, kVK_F20: NSF20FunctionKey,
        ]
        if let function = functionKeys[Int(combo.keyCode)], let scalar = UnicodeScalar(function) {
            return (String(Character(scalar)), modifiers)
        }
        let name = KeyCombo.name(for: Int(combo.keyCode)).lowercased()
        return name.count == 1 ? (name, modifiers) : ("", [])
    }

    private func buildMainMenu() {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "FastShot Hakkında", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Ayarlar…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "FastShot'u gizle", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "FastShot'tan çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "FastShot", action: nil, keyEquivalent: "").submenu = appMenu

        let fileMenu = NSMenu(title: "Dosya")
        fileMenu.addItem(withTitle: "Ekran görüntüsü al", action: #selector(takeScreenshot), keyEquivalent: "").target = self
        fileMenu.addItem(withTitle: "Alanı videoya kaydet", action: #selector(recordVideo), keyEquivalent: "").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Aç…", action: #selector(openFile), keyEquivalent: "o").target = self
        fileMenu.addItem(withTitle: "Geçmiş", action: #selector(showLibrary), keyEquivalent: "l").target = self
        fileMenu.addItem(withTitle: "Dosyaları dönüştür…", action: #selector(chooseFilesToConvert), keyEquivalent: "").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Kapat", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "Dosya", action: nil, keyEquivalent: "").submenu = fileMenu

        let editMenu = NSMenu(title: "Düzen")
        editMenu.addItem(withTitle: "Geri al", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Yinele", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Kes", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Kopyala", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Yapıştır", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Tümünü seç", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Düzen", action: nil, keyEquivalent: "").submenu = editMenu

        let windowMenu = NSMenu(title: "Pencere")
        windowMenu.addItem(withTitle: "Küçült", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Büyüt", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addItem(withTitle: "Pencere", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    private func showWelcome() {
        let shot = [prefs.screenshotHotkey, prefs.screenshotHotkeyAlt].compactMap { $0?.displayString }.joined(separator: " veya ")
        let video = [prefs.recordHotkey, prefs.recordHotkeyAlt].compactMap { $0?.displayString }.joined(separator: " veya ")
        let alert = NSAlert()
        alert.messageText = "FastShot menü çubuğunda hazır"
        alert.informativeText = """
        • \(shot): alan seç, üzerine çiz, kopyala veya kaydet
        • \(video): seçtiğin alanı videoya kaydet, kayıt sırasında ekrana çiz

        Yakalamaların çizimleriyle birlikte Geçmiş'te saklanır; istediğin zaman yeniden açıp düzenleyebilirsin.

        Mac'in kendi ekran görüntüsü tuşlarını (ör. ⇧⌘4) FastShot'a vermek için: Ayarlar › Kısayollar. FastShot'ı Uygulamalar'dan yeniden açtığında ayarlar açılır.

        Ekran görüntüsü alabilmek için macOS'un Ekran Kaydı iznine ihtiyaç var.
        """
        alert.addButton(withTitle: "İzin Ver")
        alert.addButton(withTitle: "Daha Sonra")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { _ = Permissions.ensureScreenRecording() }
    }
}
