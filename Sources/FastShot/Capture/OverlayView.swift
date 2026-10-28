import AppKit
import FastShotCore
import SwiftUI

/// Full-screen view over one display's frozen image. Handles choosing and
/// adjusting the region, hosts the annotation canvas inside it and places the
/// two toolbars around it.
@MainActor
final class OverlayView: NSView {
    unowned let session: CaptureSession
    let shot: ScreenShot
    let windowRects: [CGRect]
    private(set) var selection: CGRect?
    private(set) var canvas: CanvasView?
    private var palette: NSView?
    private var actionBar: NSView?
    private var phase: Phase = .idle
    private var mouse: CGPoint?
    private var hoverRect: CGRect?
    private var trackingArea: NSTrackingArea?

    private enum Phase {
        case idle
        case creating(start: CGPoint, moved: Bool)
        case selected
        case moving(start: CGPoint, original: CGRect)
        case resizing(handle: AnnotationHandle, original: CGRect)
    }

    init(session: CaptureSession, shot: ScreenShot, windowRects: [CGRect]) {
        self.session = session
        self.shot = shot
        self.windowRects = windowRects
        super.init(frame: CGRect(origin: .zero, size: shot.screen.frame.size))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var isVideo: Bool { session.mode == .video }
    private var isIdle: Bool { if case .idle = phase { return true } else { return false } }
    private var isChoosing: Bool {
        switch phase {
        case .idle, .creating: return true
        default: return false
        }
    }
    private var isOtherScreenActive: Bool { session.activeView != nil && session.activeView !== self }

    func croppedImage() -> CGImage? {
        guard let selection else { return nil }
        let s = shot.pointScale
        let pixels = CGRect(x: selection.minX * s, y: selection.minY * s, width: selection.width * s, height: selection.height * s).integral
        return shot.image.cropping(to: pixels.intersection(CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height)))
    }

    func resetSelection() {
        removeChrome()
        selection = nil
        phase = .idle
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .none
        AnnotationRenderer.drawImage(shot.image, in: bounds, ctx: ctx)
        let showHover = isIdle && !isOtherScreenActive
        let highlight = selection ?? (showHover ? hoverRect : nil)
        ctx.saveGState()
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.45))
        ctx.addRect(bounds)
        if let highlight { ctx.addRect(highlight) }
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        if let selection {
            drawFrame(selection, ctx: ctx, handles: !isChoosing)
            drawSizeLabel(for: selection)
        } else if showHover, let hoverRect {
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(3)
            ctx.stroke(hoverRect.insetBy(dx: 1.5, dy: 1.5))
            drawSizeLabel(for: hoverRect)
        }
        if isChoosing, !isOtherScreenActive, Preferences.shared.showMagnifier, let mouse { drawLoupe(at: mouse, ctx: ctx) }
        if isIdle, !isOtherScreenActive { drawHint() }
    }

    private func drawFrame(_ rect: CGRect, ctx: CGContext, handles: Bool) {
        ctx.setLineWidth(1)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.6))
        ctx.stroke(rect.insetBy(dx: -1.5, dy: -1.5))
        ctx.setStrokeColor(.white)
        ctx.stroke(rect.insetBy(dx: -0.5, dy: -0.5))
        guard handles else { return }
        for (_, point) in selectionHandles(rect) {
            let knob = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            ctx.setFillColor(.white)
            ctx.fill(knob)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.7))
            ctx.stroke(knob.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    private func drawSizeLabel(for rect: CGRect) {
        let s = shot.pointScale
        let text = "\(Int((rect.width * s).rounded())) × \(Int((rect.height * s).rounded()))"
        var origin = CGPoint(x: rect.minX, y: rect.minY - 26)
        if origin.y < 4 { origin.y = rect.minY + 6; origin.x += 6 }
        drawPill(text, at: origin, font: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold))
    }

    private func drawHint() {
        let text = isVideo
            ? "Kaydedilecek alanı sürükleyerek seçin  ·  Pencere için tıklayın  ·  Tam ekran: ↩  ·  Çıkış: Esc"
            : "Alanı sürükleyerek seçin  ·  Pencere için tıklayın  ·  Tam ekran: ↩  ·  Çıkış: Esc"
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let width = (text as NSString).size(withAttributes: [.font: font]).width + 28
        drawPill(text, at: CGPoint(x: (bounds.width - width) / 2, y: 46), font: font, padding: 14, height: 30)
    }

    @discardableResult
    private func drawPill(_ text: String, at origin: CGPoint, font: NSFont, padding: CGFloat = 7, height: CGFloat = 20) -> CGRect {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        var box = CGRect(x: origin.x, y: origin.y, width: size.width + padding * 2, height: height)
        box.origin.x = min(max(4, box.minX), bounds.width - box.width - 4)
        NSColor(white: 0.08, alpha: 0.86).setFill()
        NSBezierPath(roundedRect: box, xRadius: height / 2.6, yRadius: height / 2.6).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + padding, y: box.midY - size.height / 2), withAttributes: attributes)
        return box
    }

    /// A magnified view of the pixels under the pointer with its coordinates and colour.
    private func drawLoupe(at p: CGPoint, ctx: CGContext) {
        let cells = 15, zoom: CGFloat = 8
        let side = CGFloat(cells) * zoom
        var origin = CGPoint(x: p.x + 20, y: p.y + 20)
        if origin.x + side > bounds.maxX - 4 { origin.x = p.x - 20 - side }
        if origin.y + side + 44 > bounds.maxY - 4 { origin.y = p.y - 20 - side - 44 }
        let loupe = CGRect(origin: origin, size: CGSize(width: side, height: side))
        let s = shot.pointScale
        let px = Int(p.x * s), py = Int(p.y * s)
        let half = cells / 2
        let wanted = CGRect(x: px - half, y: py - half, width: cells, height: cells)
        let available = wanted.intersection(CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height))

        ctx.saveGState()
        let clip = CGPath(roundedRect: loupe, cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.addPath(clip)
        ctx.clip()
        ctx.setFillColor(.black)
        ctx.fill(loupe)
        if !available.isNull, let crop = shot.image.cropping(to: available) {
            ctx.interpolationQuality = .none
            let target = CGRect(x: loupe.minX + (available.minX - wanted.minX) * zoom, y: loupe.minY + (available.minY - wanted.minY) * zoom,
                                width: available.width * zoom, height: available.height * zoom)
            AnnotationRenderer.drawImage(crop, in: target, ctx: ctx)
        }
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.08))
        ctx.setLineWidth(1)
        for i in 1..<cells {
            let offset = CGFloat(i) * zoom
            ctx.move(to: CGPoint(x: loupe.minX + offset, y: loupe.minY)); ctx.addLine(to: CGPoint(x: loupe.minX + offset, y: loupe.maxY))
            ctx.move(to: CGPoint(x: loupe.minX, y: loupe.minY + offset)); ctx.addLine(to: CGPoint(x: loupe.maxX, y: loupe.minY + offset))
        }
        ctx.strokePath()
        let center = CGRect(x: loupe.minX + CGFloat(half) * zoom, y: loupe.minY + CGFloat(half) * zoom, width: zoom, height: zoom)
        ctx.setStrokeColor(.white)
        ctx.setLineWidth(1.5)
        ctx.stroke(center)
        ctx.restoreGState()
        ctx.addPath(clip)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.85))
        ctx.setLineWidth(1.5)
        ctx.strokePath()

        let color = pixelColor(x: px, y: py)
        let label = "\(px), \(py)   \(color?.hex ?? "")"
        let pill = drawPill(label, at: CGPoint(x: loupe.minX, y: loupe.maxY + 6), font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium))
        if let color {
            let swatch = CGRect(x: pill.maxX + 6, y: pill.minY + 3, width: 14, height: 14)
            ctx.setFillColor(color.cgColor)
            ctx.fill(swatch)
            ctx.setStrokeColor(.white)
            ctx.stroke(swatch)
        }
    }

    private func pixelColor(x: Int, y: Int) -> RGBAColor? {
        guard x >= 0, y >= 0, x < shot.image.width, y < shot.image.height,
              let pixel = shot.image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var data = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return RGBAColor(Double(data[0]) / 255, Double(data[1]) / 255, Double(data[2]) / 255)
    }

    // MARK: Selection geometry

    private func selectionHandles(_ r: CGRect) -> [(AnnotationHandle, CGPoint)] {
        [(.topLeft, CGPoint(x: r.minX, y: r.minY)), (.top, CGPoint(x: r.midX, y: r.minY)), (.topRight, CGPoint(x: r.maxX, y: r.minY)),
         (.right, CGPoint(x: r.maxX, y: r.midY)), (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)), (.bottom, CGPoint(x: r.midX, y: r.maxY)),
         (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.left, CGPoint(x: r.minX, y: r.midY))]
    }

    /// Knobs first, then the edges themselves.
    private func selectionHandle(at p: CGPoint) -> AnnotationHandle? {
        guard let r = selection else { return nil }
        if let knob = selectionHandles(r).first(where: { Geometry.distance($0.1, p) <= 8 })?.0 { return knob }
        let edge: CGFloat = 4
        let withinX = p.x > r.minX && p.x < r.maxX, withinY = p.y > r.minY && p.y < r.maxY
        if withinX && abs(p.y - r.minY) <= edge { return .top }
        if withinX && abs(p.y - r.maxY) <= edge { return .bottom }
        if withinY && abs(p.x - r.minX) <= edge { return .left }
        if withinY && abs(p.x - r.maxX) <= edge { return .right }
        return nil
    }

    private func resized(_ r: CGRect, handle: AnnotationHandle, to p: CGPoint) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        switch handle {
        case .topLeft: minX = p.x; minY = p.y
        case .top: minY = p.y
        case .topRight: maxX = p.x; minY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom: maxY = p.y
        case .bottomLeft: minX = p.x; maxY = p.y
        case .left: minX = p.x
        case .start, .end: break
        }
        return Geometry.rect(CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY))
    }

    private func setSelection(_ rect: CGRect) {
        var r = rect.intersection(bounds)
        if r.isNull { return }
        r = CGRect(x: r.minX.rounded(), y: r.minY.rounded(), width: max(1, r.width.rounded()), height: max(1, r.height.rounded()))
        let old = selection
        selection = r
        if let canvas, let old {
            // Annotations belong to the screen content, so they stay put while the frame moves.
            let dx = old.minX - r.minX, dy = old.minY - r.minY
            if dx != 0 || dy != 0 { session.controller.translateAll(dx: dx, dy: dy) }
            canvas.frame = r
            canvas.canvasSize = r.size
            canvas.backgroundImage = croppedImage()
        }
        layoutChrome()
        needsDisplay = true
    }

    private func selectWholeScreen() {
        session.selectionBegan(in: self)
        selection = bounds
        phase = .selected
        installChrome()
        needsDisplay = true
    }

    // MARK: Mouse

    private func local(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        if case .selected = phase, selectionHandle(at: p) != nil { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let p = local(event)
        window?.makeKey()
        if case .selected = phase, let selection {
            if let handle = selectionHandle(at: p) {
                phase = .resizing(handle: handle, original: selection)
                return
            }
            if selection.contains(p) {
                phase = .moving(start: p, original: selection)
                NSCursor.closedHand.set()
                return
            }
            // Clicking outside never throws away drawings by accident.
            if session.hasAnnotations { return }
        }
        session.selectionBegan(in: self)
        removeChrome()
        selection = nil
        phase = .creating(start: p, moved: false)
        mouse = p
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = local(event)
        mouse = p
        switch phase {
        case .creating(let start, let moved):
            if moved || Geometry.distance(start, p) > 3 {
                phase = .creating(start: start, moved: true)
                setSelection(Geometry.rect(start, p))
            }
        case .moving(let start, let original):
            var r = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            r.origin.x = min(max(0, r.minX), bounds.width - r.width)
            r.origin.y = min(max(0, r.minY), bounds.height - r.height)
            setSelection(r)
        case .resizing(let handle, let original):
            setSelection(resized(original, handle: handle, to: p))
        case .idle, .selected:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch phase {
        case .creating(_, let moved):
            if !moved || (selection?.width ?? 0) < 4 || (selection?.height ?? 0) < 4 {
                // A click picks the window under the pointer, or the whole screen.
                selection = hoverRect ?? bounds
            }
            phase = .selected
            installChrome()
        case .moving, .resizing:
            phase = .selected
        case .idle, .selected:
            break
        }
        updateCursor(at: local(event))
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        if isChoosing { session.cancel() } else { super.rightMouseDown(with: event) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = local(event)
        mouse = p
        if isIdle {
            let newHover = windowRects.first { $0.contains(p) }
            if newHover != hoverRect { hoverRect = newHover }
            needsDisplay = true
        }
        updateCursor(at: p)
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(at: local(event)) }

    private func updateCursor(at p: CGPoint) {
        if let handle = selectionHandle(at: p), case .selected = phase {
            AnnotationController.cursor(for: handle).set()
        } else if let canvas, canvas.frame.contains(p) {
            return
        } else if let selection, !isChoosing {
            if selection.contains(p) { NSCursor.openHand.set() } else { (session.hasAnnotations ? NSCursor.arrow : NSCursor.crosshair).set() }
        } else {
            NSCursor.crosshair.set()
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if handleKey(event) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.contains(.command), handleKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch Int(event.keyCode) {
        case 53: // Esc
            if session.controller.selected != nil {
                session.controller.select(nil)
            } else {
                session.cancel()
            }
            return true
        case 36, 76: // Return, Enter
            if isChoosing {
                selectWholeScreen()
            } else if isVideo {
                session.record()
            } else {
                session.copy()
            }
            return true
        default:
            break
        }
        guard !isChoosing else { return false }
        if modifiers == [.command] {
            switch key {
            case "c": if !isVideo { session.copy() }; return true
            case "s": if !isVideo { session.save() }; return true
            case "e": if !isVideo { session.openEditor() }; return true
            case "p": if !isVideo { session.pin() }; return true
            case "t": if !isVideo { session.recognizeText() }; return true
            case "r": session.record(); return true
            default: break
            }
        }
        if modifiers == [.command, .shift], key == "s", !isVideo {
            session.saveAs()
            return true
        }
        if session.controller.selected == nil, let selection, modifiers.isEmpty || modifiers == [.shift] {
            let step: CGFloat = modifiers == [.shift] ? 10 : 1
            let offsets: [Int: CGPoint] = [123: CGPoint(x: -step, y: 0), 124: CGPoint(x: step, y: 0),
                                           125: CGPoint(x: 0, y: step), 126: CGPoint(x: 0, y: -step)]
            if let offset = offsets[Int(event.keyCode)] {
                var r = selection.offsetBy(dx: offset.x, dy: offset.y)
                r.origin.x = min(max(0, r.minX), bounds.width - r.width)
                r.origin.y = min(max(0, r.minY), bounds.height - r.height)
                setSelection(r)
                return true
            }
        }
        return false
    }

    // MARK: Canvas and toolbars

    private func installChrome() {
        removeChrome()
        guard let selection else { return }
        if !isVideo {
            let canvas = CanvasView(controller: session.controller, canvasSize: selection.size)
            canvas.drawsBackground = false
            canvas.fitsToBounds = false
            canvas.frame = selection
            canvas.backgroundImage = croppedImage()
            canvas.idleCursor = { .openHand }
            canvas.onBackgroundMouse = { [weak self] event, type in self?.backgroundMouse(event, type) }
            canvas.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
            addSubview(canvas)
            self.canvas = canvas

            let palette = ChromeHostingView(rootView: OverlayToolPalette(tools: session.tools, undo: { [weak self] in self?.session.controller.undo() },
                                                                       redo: { [weak self] in self?.session.controller.redo() }))
            addSubview(palette)
            self.palette = palette
        }
        let actions = OverlayActions(
            copy: { [weak self] in self?.session.copy() }, save: { [weak self] in self?.session.save() },
            saveAs: { [weak self] in self?.session.saveAs() }, pin: { [weak self] in self?.session.pin() },
            recognizeText: { [weak self] in self?.session.recognizeText() }, edit: { [weak self] in self?.session.openEditor() },
            record: { [weak self] in self?.session.record() }, cancel: { [weak self] in self?.session.cancel() })
        let bar = ChromeHostingView(rootView: OverlayActionBar(mode: session.mode, actions: actions))
        addSubview(bar)
        actionBar = bar
        layoutChrome()
        window?.makeFirstResponder(canvas ?? self)
    }

    private func removeChrome() {
        canvas?.endTextEditing()
        canvas?.removeFromSuperview()
        palette?.removeFromSuperview()
        actionBar?.removeFromSuperview()
        canvas = nil
        palette = nil
        actionBar = nil
    }

    private func backgroundMouse(_ event: NSEvent, _ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown:
            guard let selection else { return }
            phase = .moving(start: local(event), original: selection)
            NSCursor.closedHand.set()
        case .leftMouseDragged: mouseDragged(with: event)
        case .leftMouseUp: mouseUp(with: event)
        default: break
        }
    }

    /// Tools to the right of the region (or left, or inside), actions below it (or above, or inside).
    private func layoutChrome() {
        guard let selection else { return }
        let margin: CGFloat = 8 - ChromeMargin.value, inset: CGFloat = 6 - ChromeMargin.value
        if let palette {
            let size = palette.fittingSize
            var x = selection.maxX + margin
            if x + size.width > bounds.maxX - inset {
                x = selection.minX - margin - size.width
                if x < inset { x = selection.maxX - size.width - margin }
            }
            let y = min(max(inset, selection.minY), bounds.maxY - size.height - inset)
            palette.frame = CGRect(x: max(inset, x), y: y, width: size.width, height: size.height)
        }
        if let actionBar {
            let size = actionBar.fittingSize
            var y = selection.maxY + margin
            if y + size.height > bounds.maxY - inset {
                y = selection.minY - margin - size.height
                if y < inset { y = selection.maxY - size.height - margin }
            }
            var x = selection.maxX - size.width
            x = min(max(inset, x), bounds.maxX - size.width - inset)
            actionBar.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        }
    }
}

struct OverlayActions {
    let copy: () -> Void
    let save: () -> Void
    let saveAs: () -> Void
    let pin: () -> Void
    let recognizeText: () -> Void
    let edit: () -> Void
    let record: () -> Void
    let cancel: () -> Void
}

struct OverlayToolPalette: View {
    @ObservedObject var tools: ToolState
    let undo: () -> Void
    let redo: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            LazyVGrid(columns: [GridItem(.fixed(30), spacing: 3), GridItem(.fixed(30), spacing: 3)], spacing: 3) {
                ForEach(EditorTool.allCases) { tool in
                    IconButton(symbol: tool.symbol, help: tool.help, selected: tools.tool == tool) { tools.tool = tool }
                }
            }
            Divider().frame(width: 56)
            ColorSwatches(tools: tools, colors: Array(RGBAColor.palette.prefix(8)), columns: 4, swatch: 10)
            Divider().frame(width: 56)
            SizePicker(tools: tools, axis: .horizontal, dotWidth: 16)
            HStack(spacing: 1) {
                IconButton(symbol: tools.filled ? "square.fill" : "square", help: "Dolgulu şekil / etiket", selected: tools.filled, size: 22) { tools.filled.toggle() }
                IconButton(symbol: "arrow.uturn.backward", help: "Geri al (⌘Z)", size: 22, action: undo).disabled(!tools.canUndo)
                IconButton(symbol: "arrow.uturn.forward", help: "Yinele (⇧⌘Z)", size: 22, action: redo).disabled(!tools.canRedo)
            }
        }
        .padding(6)
        .hudBackground()
        .padding(ChromeMargin.value)
    }
}

struct OverlayActionBar: View {
    let mode: CaptureSession.Mode
    let actions: OverlayActions
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        HStack(spacing: 2) {
            if mode == .screenshot {
                IconButton(symbol: "doc.on.doc", help: "Panoya kopyala (⌘C veya ↩)", action: actions.copy)
                IconButton(symbol: "square.and.arrow.down", help: "Kaydet (⌘S)", action: actions.save)
                IconButton(symbol: "folder", help: "Farklı kaydet… (⇧⌘S)", action: actions.saveAs)
                separator
                IconButton(symbol: "pin", help: "Ekrana sabitle (⌘P)", action: actions.pin)
                IconButton(symbol: "text.viewfinder", help: "Metni tanı ve kopyala (⌘T)", action: actions.recognizeText)
                IconButton(symbol: "slider.horizontal.below.rectangle", help: "Düzenleyicide aç (⌘E)", action: actions.edit)
                IconButton(symbol: "record.circle", help: "Bu alanı videoya kaydet (⌘R)", tint: .red, action: actions.record)
                separator
                IconButton(symbol: "xmark", help: "Kapat (Esc)", action: actions.cancel)
            } else {
                IconButton(symbol: prefs.recordMicrophone ? "mic.fill" : "mic.slash", help: "Mikrofon", selected: prefs.recordMicrophone) {
                    prefs.recordMicrophone.toggle()
                }
                IconButton(symbol: prefs.recordSystemAudio ? "speaker.wave.2.fill" : "speaker.slash", help: "Sistem sesi", selected: prefs.recordSystemAudio) {
                    prefs.recordSystemAudio.toggle()
                }
                IconButton(symbol: "cursorarrow", help: "İmleci göster", selected: prefs.showCursor) { prefs.showCursor.toggle() }
                separator
                Button(action: actions.record) {
                    Label("Kaydı Başlat", systemImage: "record.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Color.red))
                }
                .buttonStyle(.plain)
                .help("Kaydı başlat (↩)")
                IconButton(symbol: "xmark", help: "İptal (Esc)", action: actions.cancel)
            }
        }
        .padding(5)
        .hudBackground(radius: 10)
        .padding(ChromeMargin.value)
    }

    private var separator: some View { Divider().frame(height: 20).padding(.horizontal, 3) }
}
