import AVFoundation
import AppKit
import Combine
import FastShotCore
import ScreenCaptureKit
import SwiftUI

enum RecordingError: LocalizedError {
    case displayMissing
    case fileMissing

    var errorDescription: String? {
        switch self {
        case .displayMissing: return "Kaydedilecek ekran bulunamadı."
        case .fileMissing: return "Kayıt dosyası oluşturulamadı."
        }
    }
}

@MainActor
final class RecordingHUDModel: ObservableObject {
    @Published var elapsed: Double = 0
    @Published var isRecording = false
    @Published var drawing = false
    @Published var countdown = 0
}

/// Records one screen region with ScreenCaptureKit. FastShot's own windows are
/// excluded from the capture, so marks drawn live during the recording are kept
/// as timed, editable annotations instead of being baked into the pixels.
@MainActor
final class RecordingSession: NSObject {
    let request: RecordRequest
    let tools = ToolState(tool: .pen)
    let controller: AnnotationController
    let model = RecordingHUDModel()
    var onFinish: ((CaptureProject?) -> Void)?
    var onTick: ((Double) -> Void)?

    private let library = AppController.shared.library
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var project: CaptureProject?
    private var startDate: Date?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var borderWindow: NSWindow?
    private var drawPanel: LivePanel?
    private var canvas: CanvasView?
    private var hudPanel: NSPanel?
    private var countdownWindow: NSWindow?
    private var timer: Timer?
    private var stopping = false
    private var cancelled = false
    private var finished = false
    private var previousApp: NSRunningApplication?
    private var observers = Set<AnyCancellable>()

    init(request: RecordRequest) {
        self.request = request
        controller = AnnotationController(tools: tools)
        super.init()
        controller.allowedTools = EditorTool.live
        controller.time = TimeContext(current: 0, duration: 0, defaultLength: nil, live: true)
        controller.clock = { [weak self] in self?.elapsed ?? 0 }
    }

    var elapsed: Double { startDate.map { Date().timeIntervalSince($0) } ?? 0 }
    var isActive: Bool { !finished }

    /// The region in Cocoa global coordinates.
    private var region: CGRect {
        let screen = request.screen.frame
        return CGRect(x: screen.minX + request.rect.minX, y: screen.maxY - request.rect.maxY, width: request.rect.width, height: request.rect.height)
    }

    // MARK: Lifecycle

    func start() async {
        showChrome()
        let prefs = Preferences.shared
        if prefs.recordMicrophone, !(await Permissions.ensureMicrophone()) {
            prefs.recordMicrophone = false
            Toast.show("Mikrofon izni yok, sessiz kaydediliyor", symbol: "mic.slash")
        }
        if prefs.countdown > 0 { await runCountdown(prefs.countdown) }
        guard !cancelled else { return }
        do {
            try await beginCapture()
        } catch {
            if let project { try? library.delete(project) }
            teardown()
            Output.showError(error, title: "Kayıt başlatılamadı")
            finish(nil)
        }
    }

    private func beginCapture() async throws {
        let prefs = Preferences.shared
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == request.displayID }) else { throw RecordingError.displayMissing }
        // Hide only the recording chrome (frame, controls, live drawing layer); other FastShot windows stay recordable.
        let chrome = Set([borderWindow, drawPanel, hudPanel, countdownWindow].compactMap { $0.map { CGWindowID($0.windowNumber) } })
        let hidden = content.windows.filter { chrome.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: hidden)

        let scale = request.screen.backingScaleFactor
        var width = request.rect.width * scale, height = request.rect.height * scale
        if prefs.videoCodec == .h264 {
            // H.264 tops out around 4096×2304; larger regions are scaled down to fit.
            let longLimit: CGFloat = 4096, shortLimit: CGFloat = 2304
            let factor = width >= height ? min(1, longLimit / width, shortLimit / height) : min(1, shortLimit / width, longLimit / height)
            width *= factor
            height *= factor
        }
        func even(_ value: CGFloat) -> Int { max(2, Int(value) & ~1) }

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = request.rect
        configuration.width = even(width)
        configuration.height = even(height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(prefs.framesPerSecond))
        configuration.showsCursor = prefs.showCursor
        configuration.queueDepth = 6
        configuration.capturesAudio = prefs.recordSystemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = prefs.recordMicrophone

        var project = try library.makeProject(kind: .video, canvasSize: request.rect.size,
                                              pixelScale: Double(CGFloat(configuration.width) / request.rect.width), mediaExtension: "mp4")
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = library.mediaURL(project)
        recordingConfiguration.outputFileType = .mp4
        recordingConfiguration.videoCodecType = prefs.videoCodec == .hevc ? .hevc : .h264
        let output = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addRecordingOutput(output)
        project.duration = 0
        self.project = project
        self.stream = stream
        self.output = output
        try await stream.startCapture()
        if startDate == nil { startDate = Date() }
        model.isRecording = true
        Output.play(.recordStart)
        startTimer()
    }

    func stop() {
        guard !stopping, !finished else { return }
        guard let stream else {
            cancelled = true
            teardown()
            finish(nil)
            return
        }
        stopping = true
        canvas?.endTextEditing()
        timer?.invalidate()
        let recordedFor = elapsed
        Task {
            await withCheckedContinuation { continuation in
                finishContinuation = continuation
                Task {
                    try? await stream.stopCapture()
                    // Don't wait forever if the finish callback never comes.
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    self.resumeFinish()
                }
            }
            await finalize(recordedFor: recordedFor)
        }
    }

    func cancel() {
        cancelled = true
        if stream != nil {
            stop()
        } else {
            teardown()
            finish(nil)
        }
    }

    private func resumeFinish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }

    private func finalize(recordedFor: Double) async {
        teardown()
        Output.play(.recordStop)
        guard var project else { finish(nil); return }
        if cancelled {
            try? library.delete(project)
            finish(nil)
            return
        }
        let url = library.mediaURL(project)
        guard FileManager.default.fileExists(atPath: url.path) else {
            try? library.delete(project)
            Output.showError(RecordingError.fileMissing, title: "Kayıt kaydedilemedi")
            finish(nil)
            return
        }
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds).flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? recordedFor
        project.duration = duration
        if let track = try? await asset.loadTracks(withMediaType: .video).first, let size = try? await track.load(.naturalSize), size.width > 0 {
            project.pixelScale = Double(size.width / project.canvasSize.width)
        }
        project.annotations = controller.annotations.map { mark in
            var mark = mark
            mark.start = min(mark.start ?? 0, duration)
            return mark
        }
        try? library.save(project)
        if let frame = try? await VideoExporter.frame(of: url, at: min(0.5, duration / 2), maxSide: 800) {
            library.writeThumbnail(frame, for: project)
        }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        finish(project)
    }

    private func finish(_ project: CaptureProject?) {
        guard !finished else { return }
        finished = true
        onFinish?(project)
    }

    // MARK: Windows

    private func showChrome() {
        let border = NSWindow(contentRect: region.insetBy(dx: -4, dy: -4), styleMask: .borderless, backing: .buffered, defer: false)
        border.isOpaque = false
        border.backgroundColor = .clear
        border.hasShadow = false
        border.ignoresMouseEvents = true
        border.level = .screenSaver
        border.isReleasedWhenClosed = false
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        border.contentView = RecordingBorderView()
        border.orderFrontRegardless()
        borderWindow = border

        let panel = LivePanel(frame: region)
        let canvas = CanvasView(controller: controller, canvasSize: request.rect.size)
        canvas.drawsBackground = false
        canvas.fitsToBounds = false
        canvas.frame = CGRect(origin: .zero, size: region.size)
        canvas.autoresizingMask = [.width, .height]
        canvas.onKeyDown = { [weak self] event in
            guard event.keyCode == 53 else { return false }
            self?.setDrawing(false)
            return true
        }
        panel.contentView = canvas
        panel.orderFrontRegardless()
        drawPanel = panel
        self.canvas = canvas

        let hud = ChromeHostingView(rootView: RecordingHUD(
            model: model, tools: tools,
            stop: { [weak self] in self?.stop() },
            cancel: { [weak self] in self?.cancel() },
            toggleDraw: { [weak self] in self?.setDrawing(!(self?.model.drawing ?? false)) },
            clear: { [weak self] in guard let self else { return }; self.controller.closeOpenAnnotations(at: self.elapsed) },
            undo: { [weak self] in self?.controller.undo() }))
        let hudPanel = NSPanel(contentRect: CGRect(origin: .zero, size: hud.fittingSize), styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        hudPanel.isOpaque = false
        hudPanel.backgroundColor = .clear
        hudPanel.hasShadow = false
        hudPanel.level = .screenSaver
        hudPanel.isReleasedWhenClosed = false
        hudPanel.becomesKeyOnlyIfNeeded = true
        hudPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hudPanel.contentView = hud
        self.hudPanel = hudPanel
        placeHUD()
        hudPanel.orderFrontRegardless()
        // Resize after SwiftUI has laid out the tools that appear with drawing mode.
        model.$drawing.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.placeHUD() } }.store(in: &observers)
    }

    /// Below the region when there's room, otherwise above, otherwise inside its bottom edge.
    private func placeHUD() {
        guard let hudPanel, let host = hudPanel.contentView else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let visible = request.screen.visibleFrame
        var origin = CGPoint(x: region.midX - size.width / 2, y: region.minY - 6 - size.height)
        if origin.y < visible.minY {
            origin.y = region.maxY + 6
            if origin.y + size.height > visible.maxY { origin.y = region.minY + 6 }
        }
        origin.x = min(max(visible.minX, origin.x), visible.maxX - size.width)
        hudPanel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    private func setDrawing(_ on: Bool) {
        guard model.isRecording || !on else { return }
        model.drawing = on
        (borderWindow?.contentView as? RecordingBorderView)?.drawing = on
        guard let drawPanel else { return }
        drawPanel.ignoresMouseEvents = !on
        if on {
            previousApp = NSWorkspace.shared.frontmostApplication
            drawPanel.makeKeyAndOrderFront(nil)
            drawPanel.makeFirstResponder(canvas)
            NSCursor.crosshair.set()
        } else {
            canvas?.endTextEditing()
            controller.select(nil)
            if let previousApp, previousApp != NSRunningApplication.current { previousApp.activate() }
        }
    }

    private func runCountdown(_ seconds: Int) async {
        let window = NSWindow(contentRect: CGRect(x: region.midX - 70, y: region.midY - 70, width: 140, height: 140),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CountdownView(model: model))
        window.orderFrontRegardless()
        countdownWindow = window
        for value in stride(from: seconds, to: 0, by: -1) {
            guard !cancelled else { break }
            model.countdown = value
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        window.orderOut(nil)
        countdownWindow = nil
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.elapsed = self.elapsed
                self.onTick?(self.elapsed)
            }
        }
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        observers.removeAll()
        canvas?.endTextEditing()
        for window in [borderWindow, drawPanel, hudPanel, countdownWindow] as [NSWindow?] { window?.orderOut(nil) }
        borderWindow = nil
        drawPanel = nil
        hudPanel = nil
        countdownWindow = nil
        canvas = nil
        model.isRecording = false
    }
}

extension RecordingSession: SCStreamDelegate, SCRecordingOutputDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard !self.stopping else { return }
            Output.showError(error, title: "Kayıt durdu")
            self.stop()
        }
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        let now = Date()
        Task { @MainActor in self.startDate = now }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            NSLog("FastShot: recording output failed: \(error)")
            self.resumeFinish()
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.resumeFinish() }
    }
}

/// Transparent panel exactly over the region; lets clicks through until drawing is switched on.
final class LivePanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
}

private final class RecordingBorderView: NSView {
    var drawing = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let color = drawing ? NSColor.controlAccentColor : NSColor.systemRed
        color.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        path.lineWidth = 2
        path.setLineDash([8, 5], count: 2, phase: 0)
        path.stroke()
    }
}

private struct CountdownView: View {
    @ObservedObject var model: RecordingHUDModel

    var body: some View {
        Text("\(model.countdown)")
            .font(.system(size: 64, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
            .frame(width: 130, height: 130)
            .background(Circle().fill(Color.black.opacity(0.65)))
    }
}

struct RecordingHUD: View {
    @ObservedObject var model: RecordingHUDModel
    @ObservedObject var tools: ToolState
    let stop: () -> Void
    let cancel: () -> Void
    let toggleDraw: () -> Void
    let clear: () -> Void
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 7) {
                Circle().fill(Color.red).frame(width: 9, height: 9).opacity(model.isRecording ? 1 : 0.35)
                Text(model.isRecording ? Self.format(model.elapsed) : "Hazırlanıyor…")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 52, alignment: .leading)
            }
            .padding(.leading, 8)
            Button(action: stop) {
                Label("Bitir", systemImage: "stop.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.red))
            }
            .buttonStyle(.plain)
            .help("Kaydı bitir (video kısayoluna tekrar basabilirsiniz)")
            Divider().frame(height: 20).padding(.horizontal, 2)
            IconButton(symbol: "pencil.tip.crop.circle", help: model.drawing ? "Çizimi kapat (Esc)" : "Ekrana çiz", selected: model.drawing, size: 28, action: toggleDraw)
                .disabled(!model.isRecording)
            if model.drawing {
                ForEach(EditorTool.live) { tool in
                    IconButton(symbol: tool.symbol, help: tool.help, selected: tools.tool == tool, size: 26) { tools.tool = tool }
                }
                Divider().frame(height: 20).padding(.horizontal, 2)
                ColorSwatches(tools: tools, colors: [.red, .orange, .yellow, .green, .blue, .white], columns: 6, swatch: 11)
                SizePicker(tools: tools, axis: .horizontal, dotWidth: 16)
                IconButton(symbol: "arrow.uturn.backward", help: "Geri al (⌘Z)", size: 26, action: undo).disabled(!tools.canUndo)
                IconButton(symbol: "trash", help: "Ekrandaki çizimleri kaldır", size: 26, action: clear)
            }
            Divider().frame(height: 20).padding(.horizontal, 2)
            IconButton(symbol: "xmark", help: "Kaydı iptal et", size: 26, action: cancel)
        }
        .padding(5)
        .fixedSize()
        .hudBackground(radius: 12)
        .padding(ChromeMargin.value)
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
