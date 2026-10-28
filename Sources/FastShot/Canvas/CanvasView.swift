import AppKit
import FastShotCore

/// Paints a background plus its annotations and feeds mouse and keyboard input
/// to an `AnnotationController`. Used by the capture overlay (1:1, transparent),
/// the image editor and the video editor (scaled to fit, with a frame behind).
@MainActor
final class CanvasView: NSView, NSTextViewDelegate {
    let controller: AnnotationController
    var canvasSize: CGSize { didSet { needsLayout = true; needsDisplay = true } }
    /// Pixels behind the canvas; also what pixelation samples.
    var backgroundImage: CGImage? { didSet { needsDisplay = true } }
    var drawsBackground = true
    var fitsToBounds = true
    var letterboxColor: NSColor?

    /// Called with mouse events that land on empty canvas while the select tool is active.
    var onBackgroundMouse: ((NSEvent, NSEvent.EventType) -> Void)?
    /// Gets keys before the canvas does; return true to consume.
    var onKeyDown: ((NSEvent) -> Bool)?
    /// Cursor to use where the controller has no opinion.
    var idleCursor: () -> NSCursor = { .arrow }

    private var routingToBackground = false
    private var textView: NSTextView?
    private var editingID: UUID?
    private var trackingArea: NSTrackingArea?

    init(controller: AnnotationController, canvasSize: CGSize) {
        self.controller = controller
        self.canvasSize = canvasSize
        super.init(frame: CGRect(origin: .zero, size: canvasSize))
        controller.onBeginTextEditing = { [weak self] id in self?.beginTextEditing(id) }
        controller.onDisplay = { [weak self] in
            self?.needsDisplay = true
            self?.styleTextView()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    var scale: CGFloat {
        guard fitsToBounds, canvasSize.width > 0, canvasSize.height > 0 else { return 1 }
        return max(0.05, min(bounds.width / canvasSize.width, bounds.height / canvasSize.height))
    }

    var canvasOrigin: CGPoint {
        guard fitsToBounds else { return .zero }
        let s = scale
        return CGPoint(x: ((bounds.width - canvasSize.width * s) / 2).rounded(), y: ((bounds.height - canvasSize.height * s) / 2).rounded())
    }

    func toCanvas(_ p: CGPoint) -> CGPoint {
        let o = canvasOrigin, s = scale
        return CGPoint(x: (p.x - o.x) / s, y: (p.y - o.y) / s)
    }

    func toView(_ p: CGPoint) -> CGPoint {
        let o = canvasOrigin, s = scale
        return CGPoint(x: o.x + p.x * s, y: o.y + p.y * s)
    }

    func toView(_ r: CGRect) -> CGRect {
        let origin = toView(r.origin)
        return CGRect(x: origin.x, y: origin.y, width: r.width * scale, height: r.height * scale)
    }

    var canvasRectInView: CGRect { toView(CGRect(origin: .zero, size: canvasSize)) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if let letterboxColor {
            ctx.setFillColor(letterboxColor.cgColor)
            ctx.fill(bounds)
        }
        ctx.saveGState()
        let origin = canvasOrigin, s = scale
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: s, y: s)
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        ctx.clip(to: canvasRect)
        if drawsBackground {
            if let backgroundImage {
                ctx.interpolationQuality = s < 1 ? .high : .medium
                AnnotationRenderer.drawImage(backgroundImage, in: canvasRect, ctx: ctx)
            } else {
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fill(canvasRect)
            }
        }
        let marks = controller.visible.filter { $0.id != editingID }
        AnnotationRenderer.draw(marks, in: ctx, background: backgroundImage, canvasSize: canvasSize)
        ctx.restoreGState()
        drawSelectionChrome(ctx)
    }

    private func drawSelectionChrome(_ ctx: CGContext) {
        guard let a = controller.selected, a.id != editingID,
              controller.visible.contains(where: { $0.id == a.id }) else { return }
        let accent = NSColor.controlAccentColor.cgColor
        ctx.saveGState()
        if !a.usesEndpoints {
            var outline = toView(a.frame)
            if a.kind == .text || a.kind == .step { outline = outline.insetBy(dx: -3, dy: -3) }
            ctx.setLineWidth(1)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.5))
            ctx.stroke(outline.insetBy(dx: -0.5, dy: -0.5))
            ctx.setStrokeColor(accent)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(outline.insetBy(dx: -0.5, dy: -0.5))
            ctx.setLineDash(phase: 0, lengths: [])
        }
        for (_, point) in a.handles {
            let c = toView(point)
            let knob = CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9)
            ctx.setFillColor(.white)
            ctx.fillEllipse(in: knob)
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: knob)
        }
        ctx.restoreGState()
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    private var tolerance: CGFloat { 8 / scale }

    override func mouseDown(with event: NSEvent) {
        if editingID != nil {
            let p = convert(event.locationInWindow, from: nil)
            if let textView, textView.frame.contains(p) { return }
            endTextEditing()
        }
        window?.makeFirstResponder(self)
        let p = toCanvas(convert(event.locationInWindow, from: nil))
        let result = controller.mouseDown(at: p, clickCount: event.clickCount, shift: event.modifierFlags.contains(.shift), tolerance: tolerance)
        routingToBackground = result == .background
        if routingToBackground { onBackgroundMouse?(event, .leftMouseDown) }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if routingToBackground {
            onBackgroundMouse?(event, .leftMouseDragged)
            return
        }
        controller.mouseDragged(to: toCanvas(convert(event.locationInWindow, from: nil)), shift: event.modifierFlags.contains(.shift))
        if controller.isDragging, controller.tools.tool == .select || controller.selected != nil { NSCursor.closedHand.set() }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if routingToBackground {
            routingToBackground = false
            onBackgroundMouse?(event, .leftMouseUp)
            return
        }
        controller.mouseUp()
        updateCursor(event)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(event) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }

    private func updateCursor(_ event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard bounds.contains(viewPoint) else { return }
        if let textView, textView.frame.contains(viewPoint) { NSCursor.iBeam.set(); return }
        (controller.cursor(at: toCanvas(viewPoint), tolerance: tolerance) ?? idleCursor()).set()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        if EditorShortcuts.handle(event, controller: controller) { needsDisplay = true; return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        if onKeyDown?(event) == true { return true }
        if EditorShortcuts.handle(event, controller: controller) { needsDisplay = true; return true }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Text editing

    var isEditingText: Bool { editingID != nil }

    private func beginTextEditing(_ id: UUID) {
        if editingID != nil { endTextEditing() }
        guard let a = controller.annotation(id) else { return }
        editingID = id
        let field = NSTextView(frame: .zero)
        field.delegate = self
        field.isRichText = false
        field.importsGraphics = false
        field.allowsUndo = true
        field.isAutomaticQuoteSubstitutionEnabled = false
        field.isAutomaticDashSubstitutionEnabled = false
        field.isAutomaticTextReplacementEnabled = false
        field.isAutomaticSpellingCorrectionEnabled = false
        field.isContinuousSpellCheckingEnabled = false
        field.isHorizontallyResizable = false
        field.isVerticallyResizable = false
        field.textContainer?.widthTracksTextView = false
        field.textContainer?.heightTracksTextView = false
        field.textContainer?.containerSize = CGSize(width: 100_000, height: 100_000)
        field.textContainer?.lineFragmentPadding = 0
        field.string = a.text
        addSubview(field)
        textView = field
        styleTextView()
        window?.makeFirstResponder(field)
        field.setSelectedRange(NSRange(location: (a.text as NSString).length, length: 0))
        needsDisplay = true
    }

    /// Keeps the live text field matching the mark it edits (font, colours, position).
    func styleTextView() {
        guard let id = editingID, let a = controller.annotation(id), let field = textView else { return }
        let s = scale
        let pad = AnnotationRenderer.textPadding(fontSize: a.fontSize)
        let ink = a.filled ? a.color.contrasting : a.color
        field.font = NSFont.systemFont(ofSize: a.fontSize * s, weight: .semibold)
        field.textColor = NSColor(cgColor: ink.cgColor)
        field.insertionPointColor = NSColor(cgColor: ink.cgColor) ?? .white
        field.drawsBackground = a.filled
        field.backgroundColor = NSColor(cgColor: a.color.cgColor) ?? .clear
        field.textContainerInset = NSSize(width: pad.width * s, height: pad.height * s)
        var frame = toView(a.bounds)
        frame.size.width += 6
        field.frame = frame.integral
        field.wantsLayer = true
        field.layer?.cornerRadius = a.filled ? min(frame.height / 4, 10) : 0
        field.layer?.borderWidth = a.filled ? 0 : 1
        field.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
    }

    func textDidChange(_ notification: Notification) {
        guard let id = editingID, let field = textView else { return }
        controller.update(id, notify: false) { $0.text = field.string }
        styleTextView()
    }

    func textDidEndEditing(_ notification: Notification) { endTextEditing() }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endTextEditing()
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            endTextEditing()
            return true
        }
        return false
    }

    func endTextEditing() {
        guard let id = editingID, let field = textView else { return }
        editingID = nil
        textView = nil
        field.delegate = nil
        let text = field.string
        field.removeFromSuperview()
        controller.finishTextEditing(id, text: text)
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        styleTextView()
    }
}
