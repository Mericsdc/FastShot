import AppKit
import FastShotCore
import QuickLookThumbnailing
import SwiftUI

/// The ring that opens around the pointer: convert, tools or actions for the
/// dragged files. Tap another wheel's key (or use the bar above the ring) to
/// switch wheels; drop on a segment, or click one, to run it.
@MainActor
final class ConversionWheel: NSObject, NSWindowDelegate {
    static let shared = ConversionWheel()

    private var panel: WheelPanel?
    private var model: WheelModel?
    private var hideTask: Task<Void, Never>?

    var isVisible: Bool { panel != nil }

    /// `point` is in Cocoa screen coordinates. `interactive` wheels are clicked rather than dropped on.
    func show(files: [URL], at point: CGPoint, interactive: Bool, mode: WheelMode = .convert) {
        let model = WheelModel(files: files, interactive: interactive)
        guard let start = model.firstAvailable(from: mode) else {
            if interactive {
                Toast.show("Bu dosyalar için seçenek yok", symbol: "exclamationmark.triangle.fill",
                           detail: "Dönüştürme ve araçlar için aynı türden dosyalar seçin")
            }
            return
        }
        dismiss()
        model.mode = start
        let view = WheelContainerView(model: model)
        view.onChoose = { [weak self] item, urls in
            self?.dismiss()
            ConversionCenter.shared.perform(item, on: urls)
        }
        view.onCancel = { [weak self] in self?.dismiss() }

        let size = WheelGeometry.windowSize
        let center = CGPoint(x: point.x, y: point.y - WheelGeometry.barHeight / 2)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        var frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        if let visible = screen?.visibleFrame {
            let slack = WheelGeometry.margin
            frame.origin.x = min(max(visible.minX - slack, frame.minX), visible.maxX - size.width + slack)
            frame.origin.y = min(max(visible.minY - slack, frame.minY), visible.maxY - size.height)
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
        self.model = model
    }

    /// A wheel key was tapped while the wheel is open: its own wheel, or the next one when it is already showing.
    func switchMode(_ mode: WheelMode) {
        guard let model else { return }
        if model.mode == mode { model.selectNext() } else { model.select(mode) }
    }

    /// The single wheel key was tapped again.
    func nextMode() { model?.selectNext() }

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
        model = nil
        panel.delegate = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; panel.animator().alphaValue = 0 }) { panel.orderOut(nil) }
    }

    func windowDidResignKey(_ notification: Notification) {
        if model?.interactive == true { dismiss() }
    }
}

final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

enum WheelGeometry {
    static let outerRadius: CGFloat = 166
    static let innerRadius: CGFloat = 66
    static let margin: CGFloat = 34
    static let barHeight: CGFloat = 58
    static let pillSize = CGSize(width: 118, height: 34)
    static let pillSpacing: CGFloat = 6
    static let barPadding: CGFloat = 4
    /// Angular gap between segments, measured at the middle of the ring.
    static let gap: CGFloat = 7

    static var side: CGFloat { (outerRadius + margin) * 2 }
    static var windowSize: CGSize { CGSize(width: side, height: side + barHeight) }
    /// Ring centre in the window's flipped (y-down) coordinates.
    static var ringCenter: CGPoint { CGPoint(x: side / 2, y: barHeight + side / 2) }

    static var barWidth: CGFloat { pillSize.width * 3 + pillSpacing * 2 + barPadding * 2 }

    static func pillFrame(_ index: Int) -> CGRect {
        let x = (side - barWidth) / 2 + barPadding + CGFloat(index) * (pillSize.width + pillSpacing)
        return CGRect(x: x, y: (barHeight - pillSize.height) / 2 + 2, width: pillSize.width, height: pillSize.height)
    }

    static func step(_ count: Int) -> Double { 2 * .pi / Double(max(1, count)) }
    /// The first segment is centred at the top; segments run clockwise.
    static func start(_ count: Int) -> Double { -.pi / 2 - step(count) / 2 }
    static func midAngle(_ index: Int, _ count: Int) -> Double { start(count) + (Double(index) + 0.5) * step(count) }
}

@MainActor
final class WheelModel: ObservableObject {
    let files: [URL]
    let interactive: Bool
    let family: FileFamily?
    private let itemsByMode: [WheelMode: [WheelItem]]
    @Published var mode: WheelMode = .convert { didSet { if oldValue != mode { hovered = nil } } }
    @Published var hovered: Int?
    @Published var appeared = false
    @Published var thumbnail: NSImage?

    init(files: [URL], interactive: Bool) {
        self.files = files
        self.interactive = interactive
        family = files.lazy.compactMap(FileConverter.family(of:)).first
        itemsByMode = Dictionary(uniqueKeysWithValues: WheelMode.allCases.map { ($0, WheelItem.items(for: $0, files: files)) })
    }

    var items: [WheelItem] { itemsByMode[mode] ?? [] }
    func isAvailable(_ mode: WheelMode) -> Bool { !(itemsByMode[mode] ?? []).isEmpty }

    /// The requested wheel, or the next one that has something to offer.
    func firstAvailable(from mode: WheelMode) -> WheelMode? {
        let order = WheelMode.allCases
        let start = order.firstIndex(of: mode) ?? 0
        return (0..<order.count).map { order[(start + $0) % order.count] }.first(where: isAvailable)
    }

    func select(_ mode: WheelMode) {
        guard mode != self.mode, isAvailable(mode) else { return }
        self.mode = mode
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    /// Steps to the next wheel that has something to offer.
    func selectNext() {
        let order = WheelMode.allCases
        let start = order.firstIndex(of: mode) ?? 0
        if let next = (1..<order.count).map({ order[(start + $0) % order.count] }).first(where: isAvailable) { select(next) }
    }

    var sourceLabel: String {
        let extensions = Set(files.map { $0.pathExtension.uppercased() })
        if extensions.count == 1, let ext = extensions.first, !ext.isEmpty { return ext }
        return family?.title ?? "Öğe"
    }

    var symbol: String {
        var isDirectory: ObjCBool = false
        if files.count == 1, FileManager.default.fileExists(atPath: files[0].path, isDirectory: &isDirectory), isDirectory.boolValue { return "folder" }
        return family?.symbol ?? "doc"
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

extension ConvertModifier {
    var glyph: String {
        switch self {
        case .shift: return "⇧"
        case .option: return "⌥"
        case .control: return "⌃"
        case .command: return "⌘"
        }
    }
}

/// Hosts the wheel's artwork (frosted disc + SwiftUI ring) and handles drops,
/// hovering and clicks itself so hit-testing matches the drawn geometry exactly.
/// The mode bar's buttons are left to SwiftUI.
final class WheelContainerView: NSView {
    let model: WheelModel
    var onChoose: ((WheelItem, [URL]) -> Void)?
    var onCancel: (() -> Void)?
    private var springPill: Int?
    private var springTask: Task<Void, Never>?
    private var previousFlags: NSEvent.ModifierFlags = []
    private var singleWasDown = false

    init(model: WheelModel) {
        self.model = model
        super.init(frame: CGRect(origin: .zero, size: WheelGeometry.windowSize))
        let c = WheelGeometry.ringCenter, r = WheelGeometry.outerRadius
        let disc = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)

        let shadow = NSView(frame: disc)
        shadow.wantsLayer = true
        shadow.layer?.shadowPath = CGPath(ellipseIn: CGRect(origin: .zero, size: disc.size), transform: nil)
        shadow.layer?.shadowColor = NSColor.black.cgColor
        shadow.layer?.shadowOpacity = 0.32
        shadow.layer?.shadowRadius = 22
        shadow.layer?.shadowOffset = CGSize(width: 0, height: -8)
        addSubview(shadow)

        let glass = NSVisualEffectView(frame: disc)
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.maskImage = NSImage(size: disc.size, flipped: false) { rect in
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        addSubview(glass)

        let bar = WheelGeometry.pillFrame(0).union(WheelGeometry.pillFrame(2)).insetBy(dx: -WheelGeometry.barPadding, dy: -WheelGeometry.barPadding)
        let barGlass = NSVisualEffectView(frame: bar)
        barGlass.material = .popover
        barGlass.blendingMode = .behindWindow
        barGlass.state = .active
        barGlass.wantsLayer = true
        barGlass.layer?.cornerRadius = bar.height / 2
        barGlass.layer?.masksToBounds = true
        addSubview(barGlass)

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

    /// Clicks on the mode bar go to its SwiftUI buttons; everything else is handled here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        return local.y < WheelGeometry.barHeight ? super.hitTest(point) : self
    }

    private func segment(at p: CGPoint) -> Int? {
        let count = model.items.count
        let c = WheelGeometry.ringCenter
        let dx = p.x - c.x, dy = p.y - c.y
        let distance = hypot(dx, dy)
        guard count > 0, distance >= WheelGeometry.innerRadius - 4, distance <= WheelGeometry.outerRadius + 14 else { return nil }
        var angle = atan2(Double(dy), Double(dx)) - WheelGeometry.start(count)
        while angle < 0 { angle += 2 * .pi }
        return Int(angle / WheelGeometry.step(count)) % count
    }

    private func pill(at p: CGPoint) -> Int? {
        (0..<WheelMode.allCases.count).first { WheelGeometry.pillFrame($0).insetBy(dx: -3, dy: -6).contains(p) }
    }

    private func setHovered(_ index: Int?) {
        guard model.hovered != index else { return }
        model.hovered = index
        if index != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    // MARK: Dropping

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setHovered(nil)
        springLoad(nil)
    }

    private func dragOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        springLoad(pill(at: p))
        setHovered(segment(at: p))
        guard model.hovered != nil else { return [] }
        return sender.draggingSourceOperationMask.contains(.copy) ? .copy : .generic
    }

    /// Hovering a mode pill with the files for a moment switches to that wheel.
    private func springLoad(_ index: Int?) {
        guard index != springPill else { return }
        springPill = index
        springTask?.cancel()
        guard let index else { return }
        springTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            self.model.select(WheelMode.allCases[index])
        }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { model.hovered != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let index = model.hovered, model.items.indices.contains(index) else { return false }
        let dropped = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        onChoose?(model.items[index], dropped.isEmpty ? model.files : dropped)
        return true
    }

    // MARK: Clicking and keys

    override func mouseMoved(with event: NSEvent) { setHovered(segment(at: convert(event.locationInWindow, from: nil))) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let index = segment(at: p), model.items.indices.contains(index) {
            onChoose?(model.items[index], model.files)
        } else if hypot(p.x - WheelGeometry.ringCenter.x, p.y - WheelGeometry.ringCenter.y) > WheelGeometry.outerRadius || model.interactive {
            onCancel?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    /// In a clicked wheel, the wheel keys switch wheels just like during a drag.
    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags
        let prefs = Preferences.shared
        if prefs.wheelKeyMode == .single {
            let down = prefs.singleWheelKey.isDown(flags)
            if down, !singleWasDown { model.selectNext() }
            singleWasDown = down
            return
        }
        let current = flags.intersection([.shift, .command, .control, .option])
        let pressed = current.subtracting(previousFlags)
        previousFlags = current
        if let mode = WheelMode.allCases.first(where: { pressed.contains($0.modifier.flag) }) {
            if model.mode == mode { model.selectNext() } else { model.select(mode) }
        }
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

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(model: model)
                .frame(width: WheelGeometry.side, height: WheelGeometry.barHeight)
            Ring(model: model)
                .frame(width: WheelGeometry.side, height: WheelGeometry.side)
                .id(model.mode)
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
        }
        .frame(width: WheelGeometry.windowSize.width, height: WheelGeometry.windowSize.height, alignment: .top)
        .scaleEffect(model.appeared ? 1 : 0.82, anchor: UnitPoint(x: 0.5, y: WheelGeometry.ringCenter.y / WheelGeometry.windowSize.height))
        .opacity(model.appeared ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: model.appeared)
        .animation(.spring(response: 0.26, dampingFraction: 0.8), value: model.mode)
    }
}

private struct ModeBar: View {
    @ObservedObject var model: WheelModel

    var body: some View {
        HStack(spacing: WheelGeometry.pillSpacing) {
            ForEach(WheelMode.allCases) { mode in
                let active = model.mode == mode
                let available = model.isAvailable(mode)
                Button { model.select(mode) } label: {
                    HStack(spacing: 7) {
                        Text(mode.glyph)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 22, height: 20)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(active ? Color.white.opacity(0.22) : Color.primary.opacity(0.08)))
                        Text(mode.title).font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(active ? Color.white : Color.primary)
                    .frame(width: WheelGeometry.pillSize.width, height: WheelGeometry.pillSize.height)
                    .background(Capsule().fill(active ? Color.accentColor : Color.clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!available)
                .opacity(available ? 1 : 0.35)
                .help(available ? "\(mode.title) (\(mode.glyph))" : "Bu dosyalar için \(mode.title.lowercased()) yok")
            }
        }
        .padding(WheelGeometry.barPadding)
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        .offset(y: 2)
    }
}

private struct Ring: View {
    @ObservedObject var model: WheelModel

    private let side = WheelGeometry.side
    private var center: CGPoint { CGPoint(x: side / 2, y: side / 2) }

    var body: some View {
        let items = model.items
        let count = items.count
        let step = WheelGeometry.step(count)
        let midRadius = (WheelGeometry.innerRadius + WheelGeometry.outerRadius) / 2
        let gapAngle = Double(WheelGeometry.gap / midRadius) / 2
        ZStack {
            Circle()
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                .frame(width: WheelGeometry.outerRadius * 2, height: WheelGeometry.outerRadius * 2)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let start = WheelGeometry.start(count) + Double(index) * step
                let mid = WheelGeometry.midAngle(index, count)
                let isHovered = model.hovered == index
                let lift: CGFloat = isHovered ? 7 : 0
                ZStack {
                    AnnularSector(start: start + gapAngle, end: start + step - gapAngle,
                                  inner: WheelGeometry.innerRadius + 8, outer: WheelGeometry.outerRadius - 8)
                        .fill(isHovered
                              ? AnyShapeStyle(LinearGradient(colors: [item.tint, item.tint.opacity(0.78)], startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(item.tint.opacity(0.13)))
                        .shadow(color: isHovered ? item.tint.opacity(0.45) : .clear, radius: 10)
                    SegmentLabel(item: item, highlighted: isHovered, compact: count > 7)
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
    }
}

private struct SegmentLabel: View {
    let item: WheelItem
    let highlighted: Bool
    let compact: Bool

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: item.symbol)
                .font(.system(size: compact ? 11 : 13, weight: .semibold))
                .foregroundStyle(highlighted ? Color.white.opacity(0.92) : item.tint)
            Text(item.title)
                .font(.system(size: compact ? 13 : 14.5, weight: .bold, design: .rounded))
                .foregroundStyle(highlighted ? Color.white : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let detail = item.detail {
                Text(detail)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(highlighted ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: compact ? 82 : 96)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Hub: View {
    @ObservedObject var model: WheelModel

    var body: some View {
        let diameter = (WheelGeometry.innerRadius - 4) * 2
        let item = model.hovered.flatMap { model.items.indices.contains($0) ? model.items[$0] : nil }
        ZStack {
            Circle()
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
                .overlay(Circle().strokeBorder((item?.tint ?? Color.primary).opacity(item == nil ? 0.1 : 0.7), lineWidth: item == nil ? 1 : 2))
            VStack(spacing: 5) {
                preview
                if let item {
                    if case .convert = item.kind {
                        HStack(spacing: 3) {
                            Text(model.sourceLabel).foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                            Text(item.title).foregroundStyle(item.tint)
                        }
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                    } else {
                        Text(item.title).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(item.tint)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                } else {
                    Text(model.files.count == 1 ? model.sourceLabel : "\(model.files.count) öğe")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                    Text(model.interactive ? "Seçin" : "Üzerine bırakın")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            .frame(width: diameter - 14)
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
                Image(systemName: model.symbol)
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
