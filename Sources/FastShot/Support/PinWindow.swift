import AppKit
import FastShotCore

/// Keeps a capture floating above other windows, e.g. as a reference while you work.
@MainActor
final class PinWindow: NSPanel, NSWindowDelegate {
    private static var open: [PinWindow] = []
    private let image: CGImage
    private let pointScale: Double
    private let aspect: CGFloat

    static func show(_ image: CGImage, pointScale: Double, frame: CGRect) {
        let window = PinWindow(image: image, pointScale: pointScale, frame: frame)
        open.append(window)
        window.orderFrontRegardless()
        window.makeKey()
    }

    private init(image: CGImage, pointScale: Double, frame: CGRect) {
        self.image = image
        self.pointScale = pointScale
        self.aspect = frame.height > 0 ? frame.width / frame.height : 1
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hasShadow = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = frame.size
        delegate = self
        let view = PinView(image: image)
        view.onClose = { [weak self] in self?.close() }
        view.menu = makeMenu()
        contentView = view
    }

    override var canBecomeKey: Bool { true }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, selector) in [("Kopyala", #selector(copyImage)), ("Kaydet…", #selector(saveImage)), ("Gerçek boyut", #selector(actualSize))] {
            menu.addItem(withTitle: title, action: selector, keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Kapat", action: #selector(close), keyEquivalent: "").target = self
        return menu
    }

    @objc private func copyImage() {
        Output.copy(image: image, pointScale: pointScale)
        Toast.show("Panoya kopyalandı", symbol: "doc.on.doc.fill")
    }

    @objc private func saveImage() {
        let prefs = Preferences.shared
        guard let choice = SavePanel.run(name: Output.baseName(), directory: prefs.imageFolderURL, formats: SavePanel.imageFormats,
                                         initial: prefs.imageFormat == .png ? 0 : 1) else { return }
        do { try Output.write(image: image, to: choice.url, format: choice.format == 0 ? .png : .jpeg, pointScale: pointScale) } catch { Output.showError(error) }
    }

    @objc private func actualSize() {
        var frame = self.frame
        let size = CGSize(width: CGFloat(image.width) / pointScale, height: CGFloat(image.height) / pointScale)
        frame.origin.y += frame.height - size.height
        frame.size = size
        setFrame(frame, display: true, animate: true)
    }

    override func scrollWheel(with event: NSEvent) {
        let factor = 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.004 : 0.04)
        var frame = self.frame
        let width = min(max(80, frame.width * factor), 4000)
        let height = width / aspect
        frame.origin.x += (frame.width - width) / 2
        frame.origin.y += (frame.height - height) / 2
        frame.size = CGSize(width: width, height: height)
        setFrame(frame, display: true)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { copyImage(); return }
        super.keyDown(with: event)
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}

private final class PinView: NSView {
    let image: CGImage
    var onClose: (() -> Void)?

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
        toolTip = "Çift tıklayın veya Esc ile kapatın · Kaydırarak boyutlandırın · Sağ tık: seçenekler"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        AnnotationRenderer.drawImage(image, in: bounds, ctx: ctx)
        ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onClose?(); return }
        super.mouseDown(with: event)
    }
}
