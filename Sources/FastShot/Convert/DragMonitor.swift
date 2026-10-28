import AppKit

/// Notices when files are being dragged anywhere (Finder, desktop, other apps) and
/// the trigger key is tapped meanwhile. It polls the mouse button, the drag
/// pasteboard and the modifier keys, none of which needs extra permissions.
@MainActor
final class DragMonitor {
    static let shared = DragMonitor()

    var onTrigger: (([URL], CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    private let pasteboard = NSPasteboard(name: .drag)
    private var timer: Timer?
    private var mouseDown = false
    /// Drag pasteboard generation seen while the button was up; a newer one means a drag began.
    private var idleChangeCount = 0
    private var modifierWasDown = false
    private var triggered = false

    func start() {
        guard timer == nil else { return }
        idleChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let prefs = Preferences.shared
        let down = NSEvent.pressedMouseButtons & 1 != 0
        guard down else {
            if mouseDown {
                mouseDown = false
                if triggered { onDragEnded?() }
                triggered = false
            }
            idleChangeCount = pasteboard.changeCount
            return
        }
        let active = NSEvent.modifierFlags.contains(prefs.convertModifier.flag)
        defer { modifierWasDown = active }
        if !mouseDown {
            mouseDown = true
            triggered = false
            return
        }
        // Fire on the key going down during a file drag, not on a key held before the drag.
        guard prefs.convertEnabled, !triggered, active, !modifierWasDown, pasteboard.changeCount != idleChangeCount else { return }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        triggered = true
        onTrigger?(urls, NSEvent.mouseLocation)
    }
}
