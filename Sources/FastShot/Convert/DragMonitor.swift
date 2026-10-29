import AppKit

/// Notices when files are being dragged anywhere (Finder, desktop, other apps) and
/// one of the wheel keys is tapped meanwhile. It polls the mouse button, the drag
/// pasteboard and the modifier keys, none of which needs extra permissions.
@MainActor
final class DragMonitor {
    static let shared = DragMonitor()

    /// First key tap of a drag: open the wheel of that mode.
    var onTrigger: (([URL], CGPoint, WheelMode) -> Void)?
    /// Later taps in the same drag: switch the open wheel.
    var onSwitch: ((WheelMode) -> Void)?
    var onDragEnded: (() -> Void)?

    private let pasteboard = NSPasteboard(name: .drag)
    private var timer: Timer?
    private var mouseDown = false
    /// Drag pasteboard generation seen while the button was up; a newer one means a drag began.
    private var idleChangeCount = 0
    private var previouslyDown: Set<WheelMode> = []
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
        let flags = NSEvent.modifierFlags
        let pressed = Set(WheelMode.allCases.filter { flags.contains($0.modifier.flag) })
        defer { previouslyDown = pressed }
        if !mouseDown {
            mouseDown = true
            triggered = false
            return
        }
        // React to a key going down during a file drag, not to a key held before the drag.
        guard Preferences.shared.convertEnabled, pasteboard.changeCount != idleChangeCount,
              let mode = WheelMode.allCases.first(where: { pressed.contains($0) && !previouslyDown.contains($0) }) else { return }
        if triggered {
            onSwitch?(mode)
            return
        }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        triggered = true
        onTrigger?(urls, NSEvent.mouseLocation, mode)
    }
}
