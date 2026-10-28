import AppKit
import FastShotCore

/// Timeline under the video: thumbnails with trim handles, a playhead, and one
/// bar per annotation whose ends set when the mark appears and disappears.
@MainActor
final class TimelineView: NSView {
    var controller: AnnotationController!
    var duration: Double = 0 { didSet { needsDisplay = true } }
    var currentTime: Double = 0 { didSet { if oldValue != currentTime { needsDisplay = true } } }
    var trimStart: Double = 0 { didSet { needsDisplay = true } }
    var trimEnd: Double = 0 { didSet { needsDisplay = true } }
    var thumbnails: [CGImage] = [] { didSet { needsDisplay = true } }

    var onSeek: ((Double) -> Void)?
    var onTrim: ((Double, Double) -> Void)?
    var onScrubbing: ((Bool) -> Void)?

    private let inset: CGFloat = 16
    private let rulerHeight: CGFloat = 18
    private let trackHeight: CGFloat = 40
    private let rowHeight: CGFloat = 16
    private let rowGap: CGFloat = 3
    static let maxRows = 6

    private enum Drag {
        case none
        case scrub
        case trimStart, trimEnd
        case bar(UUID, Edge, grabTime: Double, original: (Double, Double), registered: Bool)
    }
    private enum Edge { case start, end, body }
    private var drag: Drag = .none

    init() {
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static func preferredHeight(rows: Int) -> CGFloat {
        let visibleRows = CGFloat(min(max(rows, 1), maxRows))
        return 18 + 40 + 10 + visibleRows * 19 + 10
    }

    // MARK: Geometry

    private var trackWidth: CGFloat { max(1, bounds.width - inset * 2) }
    private func x(for time: Double) -> CGFloat { inset + CGFloat(duration > 0 ? time / duration : 0) * trackWidth }
    private func time(for x: CGFloat) -> Double { min(max(0, Double((x - inset) / trackWidth) * duration), duration) }
    private var trackRect: CGRect { CGRect(x: inset, y: rulerHeight, width: trackWidth, height: trackHeight) }

    private var rows: [Annotation] { controller?.annotations ?? [] }

    private func rowRect(_ index: Int) -> CGRect {
        let available = bounds.height - (rulerHeight + trackHeight + 10) - 8
        let count = max(1, rows.count)
        let height = min(rowHeight, max(5, available / CGFloat(count) - rowGap))
        return CGRect(x: inset, y: rulerHeight + trackHeight + 10 + CGFloat(index) * (height + rowGap), width: trackWidth, height: height)
    }

    private func barRect(_ a: Annotation, row: Int) -> CGRect {
        let r = rowRect(row)
        let start = x(for: a.start ?? 0), end = x(for: a.end ?? duration)
        return CGRect(x: start, y: r.minY, width: max(4, end - start), height: r.height)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        drawRuler(ctx)

        let track = trackRect
        ctx.saveGState()
        let trackPath = CGPath(roundedRect: track, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.addPath(trackPath)
        ctx.clip()
        ctx.setFillColor(NSColor.quaternaryLabelColor.cgColor)
        ctx.fill(track)
        if !thumbnails.isEmpty {
            let width = track.width / CGFloat(thumbnails.count)
            for (index, thumb) in thumbnails.enumerated() {
                let aspect = CGFloat(thumb.width) / CGFloat(max(1, thumb.height))
                let drawWidth = max(width, track.height * aspect)
                let cell = CGRect(x: track.minX + CGFloat(index) * width, y: track.minY, width: width, height: track.height)
                ctx.saveGState()
                ctx.clip(to: cell)
                AnnotationRenderer.drawImage(thumb, in: CGRect(x: cell.midX - drawWidth / 2, y: cell.minY, width: drawWidth, height: cell.height), ctx: ctx)
                ctx.restoreGState()
            }
        }
        // Dim what the trim leaves out.
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fill(CGRect(x: track.minX, y: track.minY, width: x(for: trimStart) - track.minX, height: track.height))
        ctx.fill(CGRect(x: x(for: trimEnd), y: track.minY, width: track.maxX - x(for: trimEnd), height: track.height))
        ctx.restoreGState()

        // Trim bracket.
        let yellow = NSColor.systemYellow.cgColor
        let left = x(for: trimStart), right = x(for: trimEnd)
        ctx.setStrokeColor(yellow)
        ctx.setLineWidth(3)
        ctx.stroke(CGRect(x: left, y: track.minY + 1.5, width: right - left, height: track.height - 3))
        ctx.setFillColor(yellow)
        for edge in [left, right] {
            let handle = CGRect(x: edge - 5, y: track.minY, width: 10, height: track.height)
            ctx.addPath(CGPath(roundedRect: handle, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.fillPath()
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.5))
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: edge, y: track.midY - 7)); ctx.addLine(to: CGPoint(x: edge, y: track.midY + 7))
            ctx.strokePath()
        }

        // Annotation bars.
        let selected = controller.selectedID
        if rows.isEmpty {
            let hint = "Videoya çizim eklemek için oynatma çubuğunu istediğiniz ana getirip üstteki araçlarla çizin."
            (hint as NSString).draw(at: CGPoint(x: inset, y: rowRect(0).minY), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
            ])
        }
        for (index, a) in rows.enumerated() {
            let bar = barRect(a, row: index)
            let color = NSColor(cgColor: a.color.cgColor) ?? .systemRed
            let isSelected = a.id == selected
            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.setFillColor(color.withAlphaComponent(isSelected ? 0.95 : 0.6).cgColor)
            ctx.fillPath()
            if isSelected {
                ctx.addPath(CGPath(roundedRect: bar.insetBy(dx: -1.5, dy: -1.5), cornerWidth: 5, cornerHeight: 5, transform: nil))
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
                ctx.setLineWidth(2)
                ctx.strokePath()
            }
            if bar.height >= 12, bar.width > 28 {
                let label = Self.label(for: a)
                let ink = a.color.luminance > 0.6 ? NSColor.black : NSColor.white
                ctx.saveGState()
                ctx.clip(to: bar.insetBy(dx: 4, dy: 0))
                (label as NSString).draw(at: CGPoint(x: bar.minX + 6, y: bar.midY - 7), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: ink,
                ])
                ctx.restoreGState()
            }
        }

        // Playhead.
        let head = x(for: currentTime)
        ctx.setFillColor(NSColor.controlAccentColor.cgColor)
        ctx.fill(CGRect(x: head - 1, y: rulerHeight - 4, width: 2, height: bounds.height - rulerHeight))
        ctx.move(to: CGPoint(x: head - 6, y: 2)); ctx.addLine(to: CGPoint(x: head + 6, y: 2)); ctx.addLine(to: CGPoint(x: head, y: rulerHeight - 2))
        ctx.closePath()
        ctx.fillPath()
    }

    private func drawRuler(_ ctx: CGContext) {
        guard duration > 0 else { return }
        let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        let step = steps.first { CGFloat($0 / duration) * trackWidth >= 70 } ?? 600
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        ctx.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        ctx.setLineWidth(1)
        var t = 0.0
        while t <= duration + 0.001 {
            let px = x(for: t).rounded() + 0.5
            ctx.move(to: CGPoint(x: px, y: rulerHeight - 6)); ctx.addLine(to: CGPoint(x: px, y: rulerHeight))
            ctx.strokePath()
            (Self.format(t, precise: step < 1) as NSString).draw(at: CGPoint(x: px + 3, y: 2), withAttributes: attributes)
            t += step
        }
    }

    static func label(for a: Annotation) -> String {
        switch a.kind {
        case .text: return a.text.replacingOccurrences(of: "\n", with: " ")
        case .step: return "Numara \(a.number)"
        default: return EditorTool(rawValue: a.kind.rawValue)?.title ?? a.kind.rawValue
        }
    }

    static func format(_ seconds: Double, precise: Bool = true) -> String {
        let clamped = max(0, seconds)
        let minutes = Int(clamped) / 60
        let rest = clamped - Double(minutes * 60)
        return precise ? String(format: "%02d:%04.1f", minutes, rest) : String(format: "%02d:%02d", minutes, Int(rest))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let track = trackRect
        if track.insetBy(dx: -8, dy: 0).contains(p) {
            if abs(p.x - x(for: trimStart)) <= 7 { drag = .trimStart; return }
            if abs(p.x - x(for: trimEnd)) <= 7 { drag = .trimEnd; return }
        }
        for (index, a) in rows.enumerated().reversed() {
            let bar = barRect(a, row: index)
            guard bar.insetBy(dx: -4, dy: -1).contains(p) else { continue }
            controller.select(a.id)
            let edge: Edge = abs(p.x - bar.minX) <= 6 ? .start : abs(p.x - bar.maxX) <= 6 ? .end : .body
            drag = .bar(a.id, edge, grabTime: time(for: p.x), original: (a.start ?? 0, a.end ?? duration), registered: false)
            if edge == .body, !a.isVisible(at: currentTime) { onSeek?(a.start ?? 0) }
            needsDisplay = true
            return
        }
        if p.y >= rulerHeight + trackHeight + 4 { controller.select(nil) }
        drag = .scrub
        onScrubbing?(true)
        onSeek?(time(for: p.x))
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let t = time(for: p.x)
        let minimum = 0.1
        switch drag {
        case .none: break
        case .scrub: onSeek?(t)
        case .trimStart:
            onTrim?(min(t, trimEnd - minimum), trimEnd)
            onSeek?(min(t, trimEnd - minimum))
        case .trimEnd:
            onTrim?(trimStart, max(t, trimStart + minimum))
            onSeek?(max(t, trimStart + minimum))
        case .bar(let id, let edge, let grab, let original, let registered):
            if !registered {
                controller.registerUndo()
                drag = .bar(id, edge, grabTime: grab, original: original, registered: true)
            }
            var start = original.0, end = original.1
            switch edge {
            case .start: start = min(max(0, t), end - minimum)
            case .end: end = max(min(duration, t), start + minimum)
            case .body:
                let length = end - start
                start = min(max(0, original.0 + t - grab), duration - length)
                end = start + length
            }
            controller.update(id, notify: false) { a in
                a.start = start
                a.end = end >= duration - 0.01 ? nil : end
            }
            onSeek?(edge == .end ? end : start)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .bar(let id, _, _, _, true) = drag { controller.update(id) { _ in } }
        if case .scrub = drag { onScrubbing?(false) }
        drag = .none
    }

    override func resetCursorRects() {
        let track = trackRect
        for edge in [x(for: trimStart), x(for: trimEnd)] {
            addCursorRect(CGRect(x: edge - 6, y: track.minY, width: 12, height: track.height), cursor: .resizeLeftRight)
        }
        for (index, a) in rows.enumerated() {
            let bar = barRect(a, row: index)
            addCursorRect(CGRect(x: bar.minX - 4, y: bar.minY, width: 8, height: bar.height), cursor: .resizeLeftRight)
            addCursorRect(CGRect(x: bar.maxX - 4, y: bar.minY, width: 8, height: bar.height), cursor: .resizeLeftRight)
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        window?.invalidateCursorRects(for: self)
    }
}
