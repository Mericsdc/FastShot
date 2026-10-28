import AppKit
import FastShotCore

/// A region of one display chosen for recording, in that display's points (origin top-left).
struct RecordRequest {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let rect: CGRect
}

final class OverlayWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        isMovable = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// One press of the capture shortcut: frozen screens, a selection, optional
/// annotations, then copy / save / pin / OCR / edit / record.
@MainActor
final class CaptureSession {
    enum Mode { case screenshot, video }

    let mode: Mode
    let tools = ToolState()
    let controller: AnnotationController
    var onFinish: ((CaptureSession) -> Void)?
    var onRecord: ((RecordRequest) -> Void)?
    var onOpenEditor: ((CaptureProject) -> Void)?

    private let shots: [ScreenShot]
    private let windowFrames: [CGRect]
    private var windows: [OverlayWindow] = []
    private(set) weak var activeView: OverlayView?
    private var project: CaptureProject?
    private let previousApp = NSWorkspace.shared.frontmostApplication
    private var finished = false

    init(mode: Mode, shots: [ScreenShot], windowFrames: [CGRect]) {
        self.mode = mode
        self.shots = shots
        self.windowFrames = windowFrames
        controller = AnnotationController(tools: tools)
    }

    func begin() {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        for shot in shots {
            let frame = shot.screen.frame
            let screenBounds = CGRect(origin: .zero, size: frame.size)
            // Window frames are top-left based on the main display; make them local to this screen.
            let rects = windowFrames.compactMap { r -> CGRect? in
                let local = CGRect(x: r.minX - frame.minX, y: r.minY - (mainHeight - frame.maxY), width: r.width, height: r.height)
                let clipped = local.intersection(screenBounds)
                return clipped.isNull || clipped.width < 20 || clipped.height < 20 ? nil : clipped
            }
            let window = OverlayWindow(screen: shot.screen)
            window.contentView = OverlayView(session: self, shot: shot, windowRects: rects)
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.forEach { $0.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        let window = windows.first { $0.frame.contains(mouse) } ?? windows.first
        window?.makeKey()
        window?.makeFirstResponder(window?.contentView)
        NSCursor.crosshair.set()
    }

    func selectionBegan(in view: OverlayView) {
        guard activeView !== view else { return }
        activeView?.resetSelection()
        activeView = view
        controller.load([])
        view.window?.makeKey()
        windows.forEach { $0.contentView?.needsDisplay = true }
    }

    var hasAnnotations: Bool { !controller.annotations.isEmpty }

    private var pointScale: Double { Double(activeView?.shot.pointScale ?? 2) }

    /// The selection with annotations burned in.
    private func renderedImage() -> CGImage? {
        guard let view = activeView, let rect = view.selection, let crop = view.croppedImage() else { return nil }
        view.canvas?.endTextEditing()
        return ImageExporter.flatten(background: crop, canvasSize: rect.size, annotations: controller.annotations)
    }

    // MARK: Actions

    func copy() {
        guard let image = renderedImage() else { return }
        Output.copy(image: image, pointScale: pointScale)
        storeInLibrary(rendered: image)
        Output.play(.shutter)
        finish()
        Toast.show("Panoya kopyalandı", symbol: "doc.on.doc.fill")
    }

    func save() {
        guard let image = renderedImage() else { return }
        do {
            let url = try Output.quickSave(image: image, pointScale: pointScale)
            if Preferences.shared.copyWhenSaving { Output.copy(image: image, pointScale: pointScale) }
            storeInLibrary(rendered: image)
            Output.play(.shutter)
            finish()
            Toast.show("Kaydedildi", symbol: "square.and.arrow.down.fill", detail: url.lastPathComponent, actionTitle: "Göster") { Output.reveal(url) }
        } catch {
            finish()
            Output.showError(error, title: "Görüntü kaydedilemedi")
        }
    }

    func saveAs() {
        guard let image = renderedImage() else { return }
        let prefs = Preferences.shared
        setOverlaysHidden(true)
        guard let choice = SavePanel.run(name: Output.baseName(), directory: prefs.imageFolderURL, formats: SavePanel.imageFormats,
                                         initial: prefs.imageFormat == .png ? 0 : 1) else {
            setOverlaysHidden(false)
            return
        }
        do {
            try Output.write(image: image, to: choice.url, format: choice.format == 0 ? .png : .jpeg, pointScale: pointScale)
            storeInLibrary(rendered: image)
            finish()
            Toast.show("Kaydedildi", symbol: "square.and.arrow.down.fill", detail: choice.url.lastPathComponent, actionTitle: "Göster") { Output.reveal(choice.url) }
        } catch {
            setOverlaysHidden(false)
            Output.showError(error, title: "Görüntü kaydedilemedi")
        }
    }

    func openEditor() {
        guard let image = renderedImage(), let project = storeInLibrary(rendered: image) else { return }
        finish(restoreFocus: false)
        onOpenEditor?(project)
    }

    func pin() {
        guard let view = activeView, let rect = view.selection, let image = renderedImage() else { return }
        let screen = view.shot.screen.frame
        let frame = CGRect(x: screen.minX + rect.minX, y: screen.maxY - rect.maxY, width: rect.width, height: rect.height)
        let scale = pointScale
        storeInLibrary(rendered: image)
        finish(restoreFocus: false)
        PinWindow.show(image, pointScale: scale, frame: frame)
    }

    func recognizeText() {
        guard let crop = activeView?.croppedImage() else { return }
        finish()
        Task {
            do {
                let text = try await TextRecognizer.recognize(crop)
                if text.isEmpty {
                    Toast.show("Metin bulunamadı", symbol: "text.viewfinder")
                } else {
                    Output.copy(text: text)
                    let lines = text.split(separator: "\n").count
                    Toast.show("Metin panoya kopyalandı", symbol: "text.viewfinder", detail: "\(lines) satır")
                }
            } catch {
                Output.showError(error, title: "Metin tanınamadı")
            }
        }
    }

    func record() {
        guard let view = activeView, let rect = view.selection else { return }
        let request = RecordRequest(screen: view.shot.screen, displayID: view.shot.displayID, rect: rect)
        finish(restoreFocus: true)
        onRecord?(request)
    }

    func cancel() { finish() }

    private func setOverlaysHidden(_ hidden: Bool) {
        if hidden {
            windows.forEach { $0.orderOut(nil) }
        } else {
            windows.forEach { $0.orderFrontRegardless() }
            activeView?.window?.makeKey()
        }
    }

    func finish(restoreFocus: Bool = true) {
        guard !finished else { return }
        finished = true
        activeView?.canvas?.endTextEditing()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        NSCursor.arrow.set()
        onFinish?(self)
        // Give the keyboard back to the app that was in front before the overlay.
        if restoreFocus, let previousApp, previousApp != NSRunningApplication.current { previousApp.activate() }
    }

    /// Keeps the capture and its marks so it can be reopened and edited later.
    @discardableResult
    private func storeInLibrary(rendered: CGImage) -> CaptureProject? {
        guard let view = activeView, let rect = view.selection, let crop = view.croppedImage() else { return nil }
        let library = AppController.shared.library
        do {
            var stored = try project ?? library.makeProject(kind: .image, canvasSize: rect.size, pixelScale: pointScale, mediaExtension: "png")
            if project == nil {
                guard let data = ImageExporter.encode(crop, format: .png, pointScale: pointScale) else { return nil }
                try data.write(to: library.mediaURL(stored), options: .atomic)
            }
            stored.canvasSize = rect.size
            stored.annotations = controller.annotations
            try library.save(stored)
            library.writeThumbnail(rendered, for: stored)
            project = stored
            NotificationCenter.default.post(name: .libraryDidChange, object: nil)
            return stored
        } catch {
            NSLog("FastShot: could not store capture: \(error)")
            return nil
        }
    }
}
