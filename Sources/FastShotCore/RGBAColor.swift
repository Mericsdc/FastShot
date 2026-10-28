import CoreGraphics
import Foundation

/// An sRGB colour that survives JSON round trips without colour-space surprises.
public struct RGBAColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(Double((number >> 16) & 0xFF) / 255, Double((number >> 8) & 0xFF) / 255, Double(number & 0xFF) / 255)
    }

    public var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    public func withAlpha(_ alpha: Double) -> RGBAColor { RGBAColor(red, green, blue, alpha) }

    public var hex: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// Relative luminance; picks readable ink for text drawn on a filled shape.
    public var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
    public var contrasting: RGBAColor { luminance > 0.6 ? .black : .white }

    public static let white = RGBAColor(1, 1, 1)
    public static let black = RGBAColor(0.07, 0.07, 0.08)
    public static let red = RGBAColor(0.95, 0.19, 0.19)
    public static let orange = RGBAColor(1.0, 0.55, 0.05)
    public static let yellow = RGBAColor(1.0, 0.83, 0.0)
    public static let green = RGBAColor(0.16, 0.74, 0.33)
    public static let blue = RGBAColor(0.10, 0.47, 1.0)
    public static let purple = RGBAColor(0.60, 0.32, 0.96)
    public static let pink = RGBAColor(1.0, 0.25, 0.62)
    public static let gray = RGBAColor(0.55, 0.56, 0.58)

    public static let palette: [RGBAColor] = [.red, .orange, .yellow, .green, .blue, .purple, .pink, .gray, .black, .white]
}
