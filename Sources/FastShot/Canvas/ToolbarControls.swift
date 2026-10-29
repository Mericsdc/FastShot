import FastShotCore
import SwiftUI

extension RGBAColor {
    var swiftUI: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .systemRed
        self.init(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
    }
}

/// Dark floating panel look shared by the overlay and recording bars.
struct HUDBackground: ViewModifier {
    var radius: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(white: 0.10).opacity(0.94)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    func hudBackground(radius: CGFloat = 12) -> some View { modifier(HUDBackground(radius: radius)) }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var selected = false
    var tint: Color? = nil
    var size: CGFloat = 30
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.47, weight: .medium))
                .foregroundStyle(selected ? Color.white : (tint ?? Color.primary))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Color.accentColor : Color.primary.opacity(hovered && enabled ? 0.12 : 0))
                )
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovered = $0 }
        .accessibilityLabel(help)
    }
}

struct ColorSwatches: View {
    @ObservedObject var tools: ToolState
    var colors: [RGBAColor] = RGBAColor.palette
    var columns = 2
    var swatch: CGFloat = 13

    var body: some View {
        let rows = stride(from: 0, to: colors.count, by: columns).map { Array(colors[$0..<min($0 + columns, colors.count)]) }
        VStack(spacing: 5) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: 5) {
                    ForEach(rows[row], id: \.self) { color in swatchButton(color) }
                }
            }
        }
    }

    private func swatchButton(_ color: RGBAColor) -> some View {
        let isCurrent = tools.color.hex == color.hex
        return Button { tools.color = color } label: {
            Circle()
                .fill(color.swiftUI)
                .overlay(Circle().strokeBorder(Color.white.opacity(color.luminance > 0.9 ? 0.6 : 0.18), lineWidth: 1))
                .frame(width: swatch, height: swatch)
                .padding(2)
                .overlay(Circle().strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(color.hex)
    }
}

struct SizePicker: View {
    @ObservedObject var tools: ToolState
    var axis: Axis = .vertical
    var dotWidth: CGFloat = 22

    var body: some View {
        let dots = ForEach(ToolState.lineWidths.indices, id: \.self) { index in
            Button { tools.size = index } label: {
                Circle()
                    .fill(tools.size == index ? Color.accentColor : Color.primary.opacity(0.75))
                    .frame(width: 3 + CGFloat(index) * 2.5, height: 3 + CGFloat(index) * 2.5)
                    .frame(width: dotWidth, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(ToolState.sizeNames[index])
        }
        if axis == .vertical {
            VStack(spacing: 0) { dots }
        } else {
            HStack(spacing: 0) { dots }
        }
    }
}

/// Hosts SwiftUI chrome with a transparent margin for its shadow; clicks in the margin fall through.
enum ChromeMargin { static let value: CGFloat = 8 }

final class ChromeHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.insetBy(dx: ChromeMargin.value, dy: ChromeMargin.value).contains(local) ? super.hitTest(point) : nil
    }
}
