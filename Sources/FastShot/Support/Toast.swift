import AppKit
import SwiftUI

/// A short confirmation near the bottom of the screen under the pointer.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ message: String, symbol: String = "checkmark.circle.fill", detail: String? = nil,
                     actionTitle: String? = nil, action: (() -> Void)? = nil) {
        hideTask?.cancel()
        panel?.orderOut(nil)
        let view = ToastView(message: message, symbol: symbol, detail: detail, actionTitle: actionTitle) {
            action?()
            dismiss()
        }
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = action == nil
        panel.contentView = host
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: visible.midX - host.fittingSize.width / 2, y: visible.minY + 70))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        self.panel = panel
        let seconds: Double = action == nil ? 2.2 : 5
        hideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { dismiss() }
        }
    }

    static func dismiss() {
        guard let current = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; current.animator().alphaValue = 0 }) {
            current.orderOut(nil)
        }
    }
}

private struct ToastView: View {
    let message: String
    let symbol: String
    let detail: String?
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(message).font(.system(size: 13, weight: .semibold))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            if let actionTitle {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 420)
        .hudBackground(radius: 14)
        .padding(14)
    }
}
