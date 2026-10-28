import AppKit
import FastShotCore
import QuickLookThumbnailing
import SwiftUI

/// The ring of target formats that opens around the pointer. Drop the dragged
/// files on a format (or click one, when opened from the menu or a shortcut) to convert them.
@MainActor
final class ConversionWheel: NSObject, NSWindowDelegate {
    static let shared = ConversionWheel()

    private var panel: WheelPanel?
    private var hideTask: Task<Void, Never>?

    var isVisible: Bool { panel != nil }

    /// `point` is in Cocoa screen coordinates. `interactive` wheels are clicked rather than dropped on.
    func show(files: [URL], at point: CGPoint, interactive: Bool) {
        let targets = FileConverter.targets(for: files)
        guard !targets.isEmpty, let family = files.lazy.compactMap(FileConverter.family(of:)).first else {
            if interactive {
                Toast.show("Bu dosyalar dönüştürülemiyor", symbol: "exclamationmark.triangle.fill",
                           detail: "Aynı türden görüntü, video, ses, PDF veya belge seçin")
            }
            return
        }
        dismiss()
        let model = WheelModel(files: files, targets: targets, family: family, interactive: interactive)
        let view = WheelContainerView(model: model)
        view.onChoose = { [weak self] format, urls in
            self?.dismiss()
            ConversionCenter.shared.convert(urls, to: format)
        }
        view.onCancel = { [weak self] in self?.dismiss() }

        let side = WheelGeometry.windowSide
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        var frame = CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
        if let visible = screen?.visibleFrame {
            let slack = WheelGeometry.margin
            frame.origin.x = min(max(visible.minX - slack, frame.minX), visible.maxX - side + slack)
            frame.origin.y = min(max(visible.minY - slack, frame.minY), visible.maxY - side + slack)
        }
        let panel = WheelPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = view
        panel.delegate = self
        panel.alphaValue = 0
        if interactive {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
        } else {
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        model.appeared = true
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        model.loadThumbnail()
        self.panel = panel
    }

    /// The mouse went up; give a drop on the wheel time to arrive before closing it.
    func dragEnded() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled { dismiss() }
        }
    }

    func dismiss() {
        hideTask?.cancel()
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; panel.animator().alphaValue = 0 }) { panel.orderOut(nil) }
    }

    func windowDidResignKey(_ notification: Notification) {
        if (panel?.contentView as? WheelContainerView)?.model.interactive == true { dismiss() }
    }
}

final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

enum WheelGeometry {
    static let outerRadius: CGFloat = 166
    static let innerRadius: CGFloat = 66
    static let margin: CGFloat = 34
    static var windowSide: CGFloat { (outerRadius + margin) * 2 }
    /// Angular gap between segments, measured at the middle of the ring.
    static let gap: CGFloat = 7

    static func step(_ count: Int) -> Double { 2 * .pi / Double(max(1, count)) }
    /// The first segment is centred at the top; segments run clockwise.
    static func start(_ count: Int) -> Double { -.pi / 2 - step(count) / 2 }
    static func midAngle(_ index: Int, _ count: Int) -> Double { start(count) + (Double(index) + 0.5) * step(count) }
}

@MainActor
final class WheelModel: ObservableObject {
    let files: [URL]
    let targets: [ConversionFormat]
    let family: FileFamily
    let interactive: Bool
    @Published var hovered: Int?
    @Published var appeared = false
    @Published var thumbnail: NSImage?

    init(files: [URL], targets: [ConversionFormat], family: FileFamily, interactive: Bool) {
        self.files = files
        self.targets = targets
        self.family = family
        self.interactive = interactive
    }

    var sourceLabel: String {
        let extensions = Set(files.map { $0.pathExtension.uppercased() })
        return extensions.count == 1 ? extensions.first! : family.title
    }

    func loadThumbnail() {
        guard let file = files.first else { return }
        let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: 96, height: 96), scale: 2, representationTypes: .thumbnail)
        Task {
            if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                thumbnail = representation.nsImage
            }
        }
    }
}

extension ConversionFormat {
    var tint: Color {
        switch id {
        case "png", "mp4", "docx": return .blue
        case "jpeg", "m4a", "html": return .orange
        case "heic", "hevc": return .purple
        case "webp", "flac": return .green
        case "pdf": return .red
        case "tiff", "wav", "odt": return .teal
        case "avif": return .mint
        case "gif", "mp3": return .pink
        case "mov", "doc": return .indigo
        case "aiff": return .cyan
        case "rtf": return .brown
        default: return .gray
        }
    }

    var symbol: String {
        switch kind {
        case .image, .webp: return "photo"
        case .imagesToPDF, .documentToPDF: return "doc.richtext"
        case .video: return "film"
        case .gif: return "play.rectangle.on.rectangle"
        case .audio: return "waveform"
        case .pdfPages: return "photo.on.rectangle"
        case .pdfText(let target), .document(let target):
            return target == .html ? "chevron.left.forwardslash.chevron.right" : "doc.text"
        }
    }
}

/// Hosts the wheel's artwork (frosted disc + SwiftUI ring) and handles drops,
/// hovering and clicks itself so hit-testing matches the drawn geometry exactly.
final class WheelContainerView: NSView {
    let model: WheelModel
    var onChoose: ((ConversionFormat, [URL]) -> Void)?
    var onCancel: (() -> Void)?

    init(model: WheelModel) {
        self.model = model
        let side = WheelGeometry.windowSide
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
        let discRect = bounds.insetBy(dx: WheelGeometry.margin, dy: WheelGeometry.margin)

        let shadow = NSView(frame: discRect)
        shadow.wantsLayer = true
        shadow.layer?.shadowPath = CGPath(ellipseIn: CGRect(origin: .zero, size: discRect.size), transform: nil)
        shadow.layer?.shadowColor = NSColor.black.cgColor
        shadow.layer?.shadowOpacity = 0.32
        shadow.layer?.shadowRadius = 22
        shadow.layer?.shadowOffset = CGSize(width: 0, height: -8)
        addSubview(shadow)

        let glass = NSVisualEffectView(frame: discRect)
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.maskImage = NSImage(size: discRect.size, flipped: false) { rect in
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        addSubview(glass)

        let art = NSHostingView(rootView: WheelArtwork(model: model))
        art.frame = bounds
        art.sizingOptions = []
        addSubview(art)

        registerForDraggedTypes([.fileURL])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    private func segment(at p: CGPoint) -> Int? {
        let count = model.targets.count
        let dx = p.x - center.x, dy = p.y - center.y
        let distance = hypot(dx, dy)
        guard count > 0, distance >= WheelGeometry.innerRadius - 4, distance <= WheelGeometry.outerRadius + 14 else { return nil }
        var angle = atan2(Double(dy), Double(dx)) - WheelGeometry.start(count)
        while angle < 0 { angle += 2 * .pi }
        return Int(angle / WheelGeometry.step(count)) % count
    }

    private func setHovered(_ index: Int?) {
        guard model.hovered != index else { return }
        model.hovered = index
        if index != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    // MARK: Dropping

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { setHovered(nil) }

    private func dragOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        setHovered(segment(at: convert(sender.draggingLocation, from: nil)))
        guard model.hovered != nil else { return [] }
        return sender.draggingSourceOperationMask.contains(.copy) ? .copy : .generic
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { model.hovered != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let index = model.hovered else { return false }
        let dropped = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        onChoose?(model.targets[index], dropped.isEmpty ? model.files : dropped)
        return true
    }

    // MARK: Clicking

    override func mouseMoved(with event: NSEvent) { setHovered(segment(at: convert(event.locationInWindow, from: nil))) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let index = segment(at: p) {
            onChoose?(model.targets[index], model.files)
        } else if hypot(p.x - center.x, p.y - center.y) > WheelGeometry.outerRadius || model.interactive {
            onCancel?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
}

/// Ring segment between two angles, in a y-down space.
private struct AnnularSector: Shape {
    var start: Double
    var end: Double
    var inner: CGFloat
    var outer: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.addArc(center: c, radius: outer, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
        path.addArc(center: c, radius: inner, startAngle: .radians(end), endAngle: .radians(start), clockwise: true)
        path.closeSubpath()
        return path
    }
}

private struct WheelArtwork: View {
    @ObservedObject var model: WheelModel

    private let side = WheelGeometry.windowSide
    private var center: CGPoint { CGPoint(x: side / 2, y: side / 2) }

    var body: some View {
        let count = model.targets.count
        let step = WheelGeometry.step(count)
        let midRadius = (WheelGeometry.innerRadius + WheelGeometry.outerRadius) / 2
        let gapAngle = Double(WheelGeometry.gap / midRadius) / 2
        ZStack {
            Circle()
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                .frame(width: WheelGeometry.outerRadius * 2, height: WheelGeometry.outerRadius * 2)
            ForEach(Array(model.targets.enumerated()), id: \.element.id) { index, format in
                let start = WheelGeometry.start(count) + Double(index) * step
                let mid = WheelGeometry.midAngle(index, count)
                let isHovered = model.hovered == index
                let lift: CGFloat = isHovered ? 7 : 0
                ZStack {
                    AnnularSector(start: start + gapAngle, end: start + step - gapAngle,
                                  inner: WheelGeometry.innerRadius + 8, outer: WheelGeometry.outerRadius - 8)
                        .fill(isHovered
                              ? AnyShapeStyle(LinearGradient(colors: [format.tint, format.tint.opacity(0.78)], startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(format.tint.opacity(0.13)))
                        .shadow(color: isHovered ? format.tint.opacity(0.45) : .clear, radius: 10)
                    SegmentLabel(format: format, highlighted: isHovered, compact: count > 8)
                        .position(x: center.x + cos(mid) * (midRadius + 2), y: center.y + sin(mid) * (midRadius + 2))
                }
                .offset(x: cos(mid) * lift, y: sin(mid) * lift)
                .scaleEffect(isHovered ? 1.02 : 1)
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isHovered)
            }
            Hub(model: model)
                .position(center)
        }
        .frame(width: side, height: side)
        .scaleEffect(model.appeared ? 1 : 0.8)
        .opacity(model.appeared ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: model.appeared)
    }
}

private struct SegmentLabel: View {
    let format: ConversionFormat
    let highlighted: Bool
    let compact: Bool

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: format.symbol)
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .foregroundStyle(highlighted ? Color.white.opacity(0.9) : format.tint)
            Text(format.title)
                .font(.system(size: compact ? 13 : 15, weight: .bold, design: .rounded))
                .foregroundStyle(highlighted ? Color.white : Color.primary)
            if let detail = format.detail {
                Text(detail)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(highlighted ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .fixedSize()
    }
}

private struct Hub: View {
    @ObservedObject var model: WheelModel

    var body: some View {
        let diameter = (WheelGeometry.innerRadius - 4) * 2
        let target = model.hovered.map { model.targets[$0] }
        ZStack {
            Circle()
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
                .overlay(Circle().strokeBorder((target?.tint ?? Color.primary).opacity(target == nil ? 0.1 : 0.7), lineWidth: target == nil ? 1 : 2))
            VStack(spacing: 5) {
                preview
                if let target {
                    HStack(spacing: 3) {
                        Text(model.sourceLabel).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                        Text(target.title).foregroundStyle(target.tint)
                    }
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                } else {
                    Text(model.files.count == 1 ? model.sourceLabel : "\(model.files.count) dosya")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                    Text(model.interactive ? "Biçim seçin" : "Biçime bırakın")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(.easeOut(duration: 0.15), value: model.hovered)
    }

    @ViewBuilder private var preview: some View {
        ZStack(alignment: .topTrailing) {
            if let thumbnail = model.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 46, maxHeight: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            } else {
                Image(systemName: model.family.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 46, height: 40)
            }
            if model.files.count > 1 {
                Text("\(model.files.count)")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.accentColor))
                    .offset(x: 8, y: -5)
            }
        }
    }
}
