import AppKit
import Combine
import FastShotCore
import SwiftUI

enum CropAspect: String, CaseIterable, Identifiable {
    case free, original, square, fourThree, threeTwo, sixteenNine, nineSixteen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "Serbest"
        case .original: return "Orijinal"
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .threeTwo: return "3:2"
        case .sixteenNine: return "16:9"
        case .nineSixteen: return "9:16"
        }
    }

    func ratio(for imageSize: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return imageSize.width / max(1, imageSize.height)
        case .square: return 1
        case .fourThree: return 4.0 / 3
        case .threeTwo: return 3.0 / 2
        case .sixteenNine: return 16.0 / 9
        case .nineSixteen: return 9.0 / 16
        }
    }
}

@MainActor
final class CropModel: ObservableObject {
    @Published var aspect: CropAspect = .free
    @Published var size: CGSize = .zero
}

/// Crops an image file and saves the result next to it.
@MainActor
final class CropWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [CropWindowController] = []

    private let url: URL
    private let cropView: CropView
    private let model = CropModel()

    static func show(_ url: URL) {
        guard let image = ImageExporter.load(url) else {
            Toast.show("Görüntü açılamadı", symbol: "exclamationmark.triangle.fill", detail: url.lastPathComponent)
            return
        }
        let controller = CropWindowController(url: url, image: image)
        open.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.cropView)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(url: URL, image: CGImage) {
        self.url = url
        cropView = CropView(image: image)
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let barHeight: CGFloat = 52
        let fit = min(1, screen.width * 0.75 / CGFloat(image.width), (screen.height * 0.75 - barHeight) / CGFloat(image.height))
        let content = CGSize(width: max(680, CGFloat(image.width) * fit + 48), height: max(440, CGFloat(image.height) * fit + 48 + barHeight))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: content), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Kırp — \(url.lastPathComponent)"
        window.minSize = CGSize(width: 600, height: 400)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let bar = NSHostingView(rootView: CropBar(model: model, cancel: { [weak self] in self?.close() }, apply: { [weak self] in self?.apply() }))
        bar.sizingOptions = []
        window.contentView = CropContainer(crop: cropView, bar: bar, barHeight: barHeight)
        window.center()

        cropView.onChange = { [weak self] rect in self?.model.size = rect.size }
        cropView.onCommit = { [weak self] in self?.apply() }
        cropView.onCancel = { [weak self] in self?.close() }
        model.size = cropView.crop.size
        model.$aspect.dropFirst().sink { [weak self] aspect in
            guard let self else { return }
            self.cropView.aspect = aspect.ratio(for: CGSize(width: image.width, height: image.height))
        }.store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func apply() {
        let folder = ConversionCenter.shared.destination(for: url)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let output = try FileTools.crop(url, to: cropView.crop, folder: folder)
            close()
            if Preferences.shared.revealAfterConvert { Output.reveal(output) }
            Toast.show("Kırpıldı", symbol: "crop", detail: output.lastPathComponent, actionTitle: "Göster") { Output.reveal(output) }
        } catch {
            Output.showError(error, title: "Görüntü kırpılamadı")
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}

private final class CropContainer: NSView {
    let crop: NSView
    let bar: NSView
    let barHeight: CGFloat

    init(crop: NSView, bar: NSView, barHeight: CGFloat) {
        self.crop = crop
        self.bar = bar
        self.barHeight = barHeight
        super.init(frame: .zero)
        addSubview(crop)
        addSubview(bar)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        crop.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - barHeight))
        bar.frame = CGRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
    }
}

private struct CropBar: View {
    @ObservedObject var model: CropModel
    let cancel: () -> Void
    let apply: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Picker("Oran", selection: $model.aspect) {
                ForEach(CropAspect.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 430)
            Text("\(Int(model.size.width)) × \(Int(model.size.height)) px")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button("İptal", action: cancel).keyboardShortcut(.cancelAction)
            Button("Kırp ve Kaydet", action: apply).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Shows the image with a movable, resizable crop frame. `crop` is in image pixels from the top-left.
final class CropView: NSView {
    let image: CGImage
    private(set) var crop: CGRect { didSet { onChange?(crop); needsDisplay = true } }
    var aspect: CGFloat? { didSet { applyAspect() } }
    var onChange: ((CGRect) -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    private enum Drag {
        case none
        case move(start: CGPoint, original: CGRect)
        case resize(AnnotationHandle, original: CGRect)
        case create(start: CGPoint)
    }
    private var drag: Drag = .none

    init(image: CGImage) {
        self.image = image
        crop = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var imageBounds: CGRect { CGRect(x: 0, y: 0, width: image.width, height: image.height) }

    /// Where the whole image is drawn, fitted with a margin.
    private var imageRect: CGRect {
        let area = bounds.insetBy(dx: 24, dy: 24)
        let scale = min(area.width / CGFloat(image.width), area.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    private var scale: CGFloat { imageRect.width / CGFloat(image.width) }

    private func toView(_ r: CGRect) -> CGRect {
        let base = imageRect, s = scale
        return CGRect(x: base.minX + r.minX * s, y: base.minY + r.minY * s, width: r.width * s, height: r.height * s)
    }

    private func toImage(_ p: CGPoint) -> CGPoint {
        let base = imageRect, s = scale
        return CGPoint(x: (p.x - base.minX) / s, y: (p.y - base.minY) / s)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.windowBackgroundColor.blended(withFraction: 0.35, of: .black)?.setFill()
        bounds.fill()
        ctx.interpolationQuality = .high
        AnnotationRenderer.drawImage(image, in: imageRect, ctx: ctx)
        let frame = toView(crop)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.5))
        ctx.addRect(imageRect)
        ctx.addRect(frame)
        ctx.fillPath(using: .evenOdd)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
        ctx.setLineWidth(1)
        for i in 1...2 {
            let x = frame.minX + frame.width * CGFloat(i) / 3, y = frame.minY + frame.height * CGFloat(i) / 3
            ctx.move(to: CGPoint(x: x, y: frame.minY)); ctx.addLine(to: CGPoint(x: x, y: frame.maxY))
            ctx.move(to: CGPoint(x: frame.minX, y: y)); ctx.addLine(to: CGPoint(x: frame.maxX, y: y))
        }
        ctx.strokePath()
        ctx.setStrokeColor(.white)
        ctx.setLineWidth(1.5)
        ctx.stroke(frame)
        for (_, point) in handles(frame) {
            let knob = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
            ctx.setFillColor(.white)
            ctx.fillEllipse(in: knob)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.strokeEllipse(in: knob)
        }
    }

    private func handles(_ r: CGRect) -> [(AnnotationHandle, CGPoint)] {
        [(.topLeft, CGPoint(x: r.minX, y: r.minY)), (.top, CGPoint(x: r.midX, y: r.minY)), (.topRight, CGPoint(x: r.maxX, y: r.minY)),
         (.right, CGPoint(x: r.maxX, y: r.midY)), (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)), (.bottom, CGPoint(x: r.midX, y: r.maxY)),
         (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.left, CGPoint(x: r.minX, y: r.midY))]
    }

    // MARK: Editing

    private func setCrop(_ rect: CGRect) {
        var r = rect.standardized.intersection(imageBounds)
        if r.isNull || r.width < 8 || r.height < 8 { return }
        r = CGRect(x: r.minX.rounded(), y: r.minY.rounded(), width: r.width.rounded(), height: r.height.rounded())
        crop = r
    }

    /// Largest frame of the chosen ratio that fits inside the current one, kept centred.
    private func applyAspect() {
        guard let aspect else { return }
        var r = crop
        if r.width / r.height > aspect { r.size.width = r.height * aspect } else { r.size.height = r.width / aspect }
        r.origin = CGPoint(x: crop.midX - r.width / 2, y: crop.midY - r.height / 2)
        setCrop(r)
    }

    private func resized(_ original: CGRect, _ handle: AnnotationHandle, to p: CGPoint) -> CGRect {
        var minX = original.minX, maxX = original.maxX, minY = original.minY, maxY = original.maxY
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
        var r = Geometry.rect(CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY))
        guard let aspect else { return r }
        // Keep the ratio: edges drive the other side around the centre, corners stay anchored opposite.
        switch handle {
        case .top, .bottom:
            let width = r.height * aspect
            r = CGRect(x: original.midX - width / 2, y: r.minY, width: width, height: r.height)
        case .left, .right:
            let height = r.width / aspect
            r = CGRect(x: r.minX, y: original.midY - height / 2, width: r.width, height: height)
        default:
            let width = max(r.width, r.height * aspect)
            let height = width / aspect
            let anchorX = handle == .topLeft || handle == .bottomLeft ? original.maxX : original.minX
            let anchorY = handle == .topLeft || handle == .topRight ? original.maxY : original.minY
            r = CGRect(x: anchorX == original.maxX ? anchorX - width : anchorX, y: anchorY == original.maxY ? anchorY - height : anchorY,
                       width: width, height: height)
        }
        return r.width <= imageBounds.width && r.height <= imageBounds.height ? r : original
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let frame = toView(crop)
        if let handle = handles(frame).first(where: { Geometry.distance($0.1, p) <= 9 })?.0 {
            drag = .resize(handle, original: crop)
        } else if frame.contains(p) {
            if event.clickCount == 2 { onCommit?(); return }
            drag = .move(start: toImage(p), original: crop)
            NSCursor.closedHand.set()
        } else {
            drag = .create(start: toImage(p))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = toImage(convert(event.locationInWindow, from: nil))
        switch drag {
        case .none: break
        case .move(let start, let original):
            var r = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            r.origin.x = min(max(0, r.minX), imageBounds.width - r.width)
            r.origin.y = min(max(0, r.minY), imageBounds.height - r.height)
            setCrop(r)
        case .resize(let handle, let original):
            setCrop(resized(original, handle, to: p))
        case .create(let start):
            var r = Geometry.rect(start, p)
            if let aspect { r.size.height = r.width / aspect; if p.y < start.y { r.origin.y = start.y - r.height } }
            setCrop(r)
        }
    }

    override func mouseUp(with event: NSEvent) {
        drag = .none
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        let frame = toView(crop)
        addCursorRect(frame.insetBy(dx: 10, dy: 10), cursor: .openHand)
        for (handle, point) in handles(frame) {
            addCursorRect(CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18), cursor: AnnotationController.cursor(for: handle))
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onCommit?()
        case 53: onCancel?()
        default: super.keyDown(with: event)
        }
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }
}
