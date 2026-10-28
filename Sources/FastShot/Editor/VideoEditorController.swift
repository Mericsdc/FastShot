import AVFoundation
import AppKit
import Combine
import FastShotCore
import SwiftUI
import VideoToolbox

@MainActor
final class VideoEditorState: ObservableObject {
    @Published var isPlaying = false
    @Published var current: Double = 0
    @Published var duration: Double = 0
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published var selectedTiming: (start: Double, end: Double)?
}

/// Plays a recording under an annotation canvas. Marks are drawn at the
/// playhead and live on the timeline, where their start and end can be dragged.
@MainActor
final class VideoEditorController: EditorWindowController {
    private let player: AVPlayer
    private let videoOutput: AVPlayerItemVideoOutput
    private let generator: AVAssetImageGenerator
    private let timeline: TimelineView
    private let videoState = VideoEditorState()
    private var displayLink: CADisplayLink?
    private var frameRequestInFlight = false
    private var pendingFrameTime: Double?
    private var resumeAfterScrub = false
    private var observers = Set<AnyCancellable>()

    init(project: CaptureProject, library: ProjectLibrary) {
        let url = library.mediaURL(project)
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(videoOutput)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        timeline = TimelineView()
        super.init(project: project, library: library, title: "FastShot — Video düzenleyici")
        timeline.controller = controller
        setUp(duration: project.duration ?? 0)
        Task { await loadDurationIfNeeded(asset) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var extraHeight: CGFloat { 44 + TimelineView.preferredHeight(rows: project.annotations.count) }
    override var supportsGIF: Bool { true }

    private var duration: Double { videoState.duration }

    private func setUp(duration: Double) {
        let prefs = Preferences.shared
        canvas.letterboxColor = NSColor(white: 0.08, alpha: 1)
        controller.time = TimeContext(current: 0, duration: duration, defaultLength: prefs.annotationLength > 0 ? prefs.annotationLength : nil, live: false)
        applyDuration(duration)

        let transport = NSHostingView(rootView: TransportBar(
            state: videoState,
            togglePlay: { [weak self] in self?.togglePlay() },
            setIn: { [weak self] in self?.setTrimStart() },
            setOut: { [weak self] in self?.setTrimEnd() },
            resetTrim: { [weak self] in self?.resetTrim() },
            setSelectedStart: { [weak self] in self?.setSelectedTiming(start: true) },
            setSelectedEnd: { [weak self] in self?.setSelectedTiming(start: false) }))
        transport.sizingOptions = [.intrinsicContentSize]
        let bottom = BottomStack(transport: transport, timeline: timeline)
        content.bottom = bottom
        updateBottomHeight()

        timeline.onSeek = { [weak self] time in self?.seek(to: time) }
        timeline.onTrim = { [weak self] start, end in self?.setTrim(start, end) }
        timeline.onScrubbing = { [weak self] scrubbing in
            guard let self else { return }
            if scrubbing {
                self.resumeAfterScrub = self.player.rate != 0
                self.pause()
            } else if self.resumeAfterScrub {
                self.play()
            }
        }
        let canvasDisplay = controller.onDisplay
        controller.onDisplay = { [weak self] in
            canvasDisplay?()
            self?.timeline.needsDisplay = true
            self?.refreshSelectedTiming()
        }
        let saveOnChange = controller.onChange
        controller.onChange = { [weak self] in
            saveOnChange?()
            guard let self else { return }
            self.updateBottomHeight()
            self.timeline.window?.invalidateCursorRects(for: self.timeline)
        }
        controller.onSelectionChange = { [weak self] in self?.refreshSelectedTiming() }
        prefs.$annotationLength.sink { [weak self] length in
            self?.controller.time?.defaultLength = length > 0 ? length : nil
        }.store(in: &observers)

        displayLink = canvas.displayLink(target: self, selector: #selector(tick(_:)))
        displayLink?.add(to: .main, forMode: .common)
        requestFrame(at: 0)
        loadThumbnails()
    }

    private func applyDuration(_ duration: Double) {
        videoState.duration = duration
        controller.time?.duration = duration
        timeline.duration = duration
        let range = project.trimRange ?? 0...max(duration, 0)
        videoState.trimStart = range.lowerBound
        videoState.trimEnd = range.upperBound
        timeline.trimStart = range.lowerBound
        timeline.trimEnd = range.upperBound
    }

    private func loadDurationIfNeeded(_ asset: AVURLAsset) async {
        guard let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 else { return }
        if abs(seconds - (project.duration ?? 0)) > 0.01 {
            project.duration = seconds
            applyDuration(seconds)
            scheduleSave()
        }
    }

    private func updateBottomHeight() {
        content.bottomHeight = 44 + TimelineView.preferredHeight(rows: controller.annotations.count)
    }

    // MARK: Playback

    @objc private func tick(_ link: CADisplayLink) {
        guard player.rate != 0 else { return }
        let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        if videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
           let buffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
            if let image { canvas.backgroundImage = image }
        }
        let now = player.currentTime().seconds
        if now >= videoState.trimEnd - 0.02 {
            pause()
            seek(to: videoState.trimEnd)
            return
        }
        setCurrentTime(now)
    }

    private func setCurrentTime(_ time: Double) {
        controller.time?.current = time
        timeline.currentTime = time
        if abs(videoState.current - time) > 0.05 || player.rate == 0 { videoState.current = time }
        canvas.needsDisplay = true
    }

    func togglePlay() { player.rate != 0 ? pause() : play() }

    private func play() {
        canvas.endTextEditing()
        let now = player.currentTime().seconds
        if now < videoState.trimStart || now >= videoState.trimEnd - 0.05 { seek(to: videoState.trimStart) }
        player.play()
        videoState.isPlaying = true
    }

    private func pause() {
        player.pause()
        videoState.isPlaying = false
        setCurrentTime(player.currentTime().seconds)
    }

    func seek(to time: Double) {
        let clamped = min(max(0, time), max(0, duration))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        setCurrentTime(clamped)
        if player.rate == 0 { requestFrame(at: clamped) }
    }

    /// Exact still for a paused playhead; requests coalesce while scrubbing.
    private func requestFrame(at time: Double) {
        if frameRequestInFlight {
            pendingFrameTime = time
            return
        }
        frameRequestInFlight = true
        let generator = self.generator
        Task {
            let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            if let image, self.player.rate == 0 { self.canvas.backgroundImage = image }
            self.frameRequestInFlight = false
            if let pending = self.pendingFrameTime {
                self.pendingFrameTime = nil
                self.requestFrame(at: pending)
            }
        }
    }

    private func loadThumbnails() {
        let asset = generator.asset
        Task {
            guard let seconds = try? await asset.load(.duration).seconds, seconds > 0 else { return }
            let thumbnailGenerator = AVAssetImageGenerator(asset: asset)
            thumbnailGenerator.appliesPreferredTrackTransform = true
            thumbnailGenerator.maximumSize = CGSize(width: 160, height: 90)
            let count = 14
            let times = (0..<count).map { CMTime(seconds: seconds * (Double($0) + 0.5) / Double(count), preferredTimescale: 600) }
            var images: [CGImage] = []
            for await result in thumbnailGenerator.images(for: times) {
                if case .success(_, let image, _) = result { images.append(image) }
            }
            self.timeline.thumbnails = images
        }
    }

    // MARK: Trim and timing

    private func setTrim(_ start: Double, _ end: Double) {
        videoState.trimStart = start
        videoState.trimEnd = end
        timeline.trimStart = start
        timeline.trimEnd = end
        project.trimStart = start > 0.01 ? start : nil
        project.trimEnd = end < duration - 0.01 ? end : nil
        scheduleSave()
    }

    private func setTrimStart() { setTrim(min(videoState.current, videoState.trimEnd - 0.1), videoState.trimEnd) }
    private func setTrimEnd() { setTrim(videoState.trimStart, max(videoState.current, videoState.trimStart + 0.1)) }
    private func resetTrim() { setTrim(0, duration) }

    private func setSelectedTiming(start: Bool) {
        guard let selected = controller.selected else { return }
        let now = videoState.current
        controller.registerUndo()
        controller.update(selected.id) { a in
            if start {
                a.start = min(now, (a.end ?? duration) - 0.1)
            } else {
                let end = max(now, (a.start ?? 0) + 0.1)
                a.end = end >= duration - 0.01 ? nil : end
            }
        }
    }

    private func refreshSelectedTiming() {
        videoState.selectedTiming = controller.selected.map { ($0.start ?? 0, $0.end ?? duration) }
    }

    // MARK: Keys

    override func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers.isEmpty {
            switch event.keyCode {
            case 49: togglePlay(); return true // space
            case 34: setTrimStart(); return true // I
            case 31: setTrimEnd(); return true // O
            case 33: setSelectedTiming(start: true); return true // [
            case 30: setSelectedTiming(start: false); return true // ]
            default: break
            }
        }
        if controller.selected == nil, modifiers.isEmpty || modifiers == [.shift] {
            let step = modifiers == [.shift] ? 1.0 : 1.0 / 30
            if event.keyCode == 123 { pause(); seek(to: videoState.current - step); return true }
            if event.keyCode == 124 { pause(); seek(to: videoState.current + step); return true }
        }
        return super.handleKey(event)
    }

    // MARK: Export

    private var exportRequest: VideoExportRequest {
        VideoExportRequest(source: library.mediaURL(project), canvasSize: project.canvasSize, annotations: controller.annotations,
                           trim: project.trimRange, preferHEVC: Preferences.shared.videoCodec == .hevc)
    }

    private func export(to url: URL, format: VideoFormat, completion: @escaping (URL) -> Void) {
        canvas.endTextEditing()
        saveProject()
        pause()
        state.exporting = true
        state.progress = 0
        let request = exportRequest
        let state = self.state
        Task {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await VideoExporter.export(request, to: url, format: format) { fraction in
                    Task { @MainActor in state.progress = fraction }
                }
                state.exporting = false
                completion(url)
            } catch {
                state.exporting = false
                Output.showError(error, title: "Video dışa aktarılamadı")
            }
        }
    }

    private func savedToast(_ url: URL) {
        Toast.show("Kaydedildi", symbol: "square.and.arrow.down.fill", detail: url.lastPathComponent, actionTitle: "Göster") { Output.reveal(url) }
    }

    override func save() {
        let url = Output.uniqueURL(in: Preferences.shared.videoFolderURL, base: Output.baseName(project.createdAt), ext: "mp4")
        export(to: url, format: .mp4) { [weak self] in self?.savedToast($0) }
    }

    override func saveGIF() {
        let url = Output.uniqueURL(in: Preferences.shared.videoFolderURL, base: Output.baseName(project.createdAt), ext: "gif")
        export(to: url, format: .gif) { [weak self] in self?.savedToast($0) }
    }

    override func saveAs() {
        guard let choice = SavePanel.run(name: Output.baseName(project.createdAt), directory: Preferences.shared.videoFolderURL,
                                         formats: SavePanel.videoFormats) else { return }
        let format: VideoFormat = [.mp4, .mov, .gif][choice.format]
        export(to: choice.url, format: format) { [weak self] in self?.savedToast($0) }
    }

    override func copyToClipboard() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FastShot", isDirectory: true)
        let url = folder.appendingPathComponent("\(Output.baseName(project.createdAt)).mp4")
        export(to: url, format: .mp4) { url in
            Output.copy(fileURL: url)
            Toast.show("Video panoya kopyalandı", symbol: "doc.on.doc.fill", detail: "Mesaja veya klasöre yapıştırabilirsiniz")
        }
    }

    override func windowWillClose(_ notification: Notification) {
        player.pause()
        displayLink?.invalidate()
        displayLink = nil
        observers.removeAll()
        super.windowWillClose(notification)
    }
}

/// Transport bar above the timeline.
private final class BottomStack: NSView {
    let transport: NSView
    let timeline: NSView

    init(transport: NSView, timeline: NSView) {
        self.transport = transport
        self.timeline = timeline
        super.init(frame: .zero)
        addSubview(transport)
        addSubview(timeline)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        transport.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 44)
        timeline.frame = CGRect(x: 0, y: 44, width: bounds.width, height: max(0, bounds.height - 44))
    }
}

private struct TransportBar: View {
    @ObservedObject var state: VideoEditorState
    @ObservedObject private var prefs = Preferences.shared
    let togglePlay: () -> Void
    let setIn: () -> Void
    let setOut: () -> Void
    let resetTrim: () -> Void
    let setSelectedStart: () -> Void
    let setSelectedEnd: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            IconButton(symbol: state.isPlaying ? "pause.fill" : "play.fill", help: "Oynat / duraklat (boşluk)", size: 32, action: togglePlay)
            Text("\(TimelineView.format(state.current)) / \(TimelineView.format(state.duration))")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
            Divider().frame(height: 20)
            Text("Kırp").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Button("Başlangıç", action: setIn).help("Kırpma başlangıcını oynatma çubuğuna al (I)")
            Button("Bitiş", action: setOut).help("Kırpma bitişini oynatma çubuğuna al (O)")
            Button("Sıfırla", action: resetTrim).disabled(state.trimStart < 0.01 && state.trimEnd > state.duration - 0.01)
            Text("\(TimelineView.format(state.trimStart)) – \(TimelineView.format(state.trimEnd))")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let timing = state.selectedTiming {
                Text("Seçili çizim: \(TimelineView.format(timing.start)) – \(TimelineView.format(timing.end))")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                Button("Burada başlasın", action: setSelectedStart).help("Seçili çizim oynatma çubuğunda görünsün ([)")
                Button("Burada bitsin", action: setSelectedEnd).help("Seçili çizim oynatma çubuğunda kaybolsun (])")
            } else {
                Picker("Yeni çizim süresi", selection: $prefs.annotationLength) {
                    Text("1 sn").tag(1.0)
                    Text("2 sn").tag(2.0)
                    Text("3 sn").tag(3.0)
                    Text("5 sn").tag(5.0)
                    Text("10 sn").tag(10.0)
                    Text("Sonuna kadar").tag(0.0)
                }
                .frame(width: 230)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
