import CoreGraphics
import Foundation

public enum AnnotationKind: String, Codable, CaseIterable, Sendable {
    case pen, line, arrow, rectangle, ellipse, marker, text, pixelate, step
}

public enum AnnotationHandle: CaseIterable, Sendable {
    case start, end
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

/// One editable mark on a capture. Coordinates are canvas points with a top-left
/// origin; a project's pixel scale maps them onto the captured pixels.
public struct Annotation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: AnnotationKind
    /// pen/marker: the stroke; line/arrow: start and end; boxes: two opposite corners;
    /// text: top-left corner of the label; step: centre of the badge.
    public var points: [CGPoint]
    public var color: RGBAColor
    public var lineWidth: Double
    public var fontSize: Double
    public var filled: Bool
    public var text: String
    public var number: Int
    /// Video timing, in seconds of the source recording. A `nil` start means from
    /// the beginning and a `nil` end means until the end of the recording.
    public var start: Double?
    public var end: Double?

    public init(kind: AnnotationKind, points: [CGPoint], color: RGBAColor = .red, lineWidth: Double = 4,
                fontSize: Double = 20, filled: Bool = false, text: String = "", number: Int = 1,
                start: Double? = nil, end: Double? = nil, id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
        self.fontSize = fontSize
        self.filled = filled
        self.text = text
        self.number = number
        self.start = start
        self.end = end
    }
}

extension Annotation {
    public var usesEndpoints: Bool { kind == .line || kind == .arrow }
    public var usesBox: Bool { kind == .rectangle || kind == .ellipse || kind == .pixelate }
    public var usesPath: Bool { kind == .pen || kind == .marker }

    /// Width of the painted stroke; the marker is a broad translucent nib.
    public var strokeWidth: CGFloat { kind == .marker ? max(10, CGFloat(lineWidth) * 3.5) : CGFloat(lineWidth) }
    public var stepRadius: CGFloat { max(11, CGFloat(fontSize) * 0.75) }
    public var arrowHeadLength: CGFloat { max(12, strokeWidth * 3 + 8) }

    public var box: CGRect {
        guard points.count >= 2 else { return CGRect(origin: points.first ?? .zero, size: .zero) }
        return Geometry.rect(points[0], points[1])
    }

    var pathBounds: CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The geometry handles attach to, without stroke thickness.
    public var frame: CGRect {
        switch kind {
        case .rectangle, .ellipse, .pixelate: return box
        case .pen, .marker, .line, .arrow: return pathBounds
        case .text, .step: return bounds
        }
    }

    /// Everything the mark paints, stroke included.
    public var bounds: CGRect {
        switch kind {
        case .text:
            return CGRect(origin: points.first ?? .zero, size: AnnotationRenderer.textBoxSize(text, fontSize: fontSize))
        case .step:
            let c = points.first ?? .zero, r = stepRadius
            return CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        case .pixelate:
            return box
        case .rectangle, .ellipse:
            return box.insetBy(dx: -strokeWidth / 2, dy: -strokeWidth / 2)
        case .pen, .marker, .line:
            return pathBounds.insetBy(dx: -strokeWidth / 2, dy: -strokeWidth / 2)
        case .arrow:
            return pathBounds.insetBy(dx: -arrowHeadLength, dy: -arrowHeadLength)
        }
    }

    public func isVisible(at time: Double) -> Bool {
        if let start, time + 0.0005 < start { return false }
        if let end, time > end + 0.0005 { return false }
        return true
    }

    public func contains(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        let reach = strokeWidth / 2 + tolerance
        switch kind {
        case .pen, .marker:
            guard let first = points.first else { return false }
            if points.count == 1 { return Geometry.distance(p, first) <= reach }
            for i in 1..<points.count where Geometry.distance(p, segment: points[i - 1], points[i]) <= reach { return true }
            return false
        case .line, .arrow:
            guard points.count >= 2 else { return false }
            let extra: CGFloat = kind == .arrow ? arrowHeadLength * 0.4 : 0
            return Geometry.distance(p, segment: points[0], points[1]) <= reach + extra
        case .rectangle:
            let r = box
            let outer = r.insetBy(dx: -reach, dy: -reach)
            if filled { return outer.contains(p) }
            return outer.contains(p) && !r.insetBy(dx: reach, dy: reach).contains(p)
        case .ellipse:
            let r = box
            guard r.width > 0.5, r.height > 0.5 else { return Geometry.distance(p, CGPoint(x: r.midX, y: r.midY)) <= reach }
            let rx = r.width / 2, ry = r.height / 2
            let dx = p.x - r.midX, dy = p.y - r.midY
            let n = sqrt(dx * dx / (rx * rx) + dy * dy / (ry * ry))
            if filled { return n <= 1 + reach / min(rx, ry) }
            return abs(n - 1) * min(rx, ry) <= reach
        case .pixelate, .text, .step:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    public var handles: [(AnnotationHandle, CGPoint)] {
        switch kind {
        case .line, .arrow:
            guard points.count >= 2 else { return [] }
            return [(.start, points[0]), (.end, points[1])]
        case .text, .step:
            return []
        default:
            let r = frame
            return [
                (.topLeft, CGPoint(x: r.minX, y: r.minY)), (.top, CGPoint(x: r.midX, y: r.minY)),
                (.topRight, CGPoint(x: r.maxX, y: r.minY)), (.right, CGPoint(x: r.maxX, y: r.midY)),
                (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)), (.bottom, CGPoint(x: r.midX, y: r.maxY)),
                (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.left, CGPoint(x: r.minX, y: r.midY)),
            ]
        }
    }

    public mutating func translate(dx: CGFloat, dy: CGFloat) {
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    /// Reshapes `original` so that `handle` follows `p`. Boxes may be dragged through
    /// themselves; strokes scale with their bounding box.
    public static func resized(_ original: Annotation, handle: AnnotationHandle, to p: CGPoint, constrain: Bool) -> Annotation {
        var a = original
        switch handle {
        case .start, .end:
            guard a.points.count >= 2 else { return a }
            let index = handle == .start ? 0 : 1
            let anchor = a.points[1 - index]
            a.points[index] = constrain ? Geometry.snapAngle(from: anchor, to: p) : p
            return a
        default:
            let old = original.frame
            var minX = old.minX, maxX = old.maxX, minY = old.minY, maxY = old.maxY
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
            if a.usesBox {
                a.points = [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY)]
            } else if a.usesPath {
                func map(_ v: CGFloat, _ oldMin: CGFloat, _ oldLength: CGFloat, _ newMin: CGFloat, _ newMax: CGFloat) -> CGFloat {
                    oldLength > 0.5 ? newMin + (v - oldMin) * (newMax - newMin) / oldLength : v + (newMin - oldMin)
                }
                a.points = original.points.map {
                    CGPoint(x: map($0.x, old.minX, old.width, minX, maxX), y: map($0.y, old.minY, old.height, minY, maxY))
                }
            }
            return a
        }
    }

    /// Too small to be anything but an accidental click.
    public var isDegenerate: Bool {
        switch kind {
        case .line, .arrow: return points.count < 2 || Geometry.distance(points[0], points[1]) < 3
        case .rectangle, .ellipse, .pixelate: return box.width < 3 || box.height < 3
        case .pen, .marker: return points.isEmpty
        case .text: return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .step: return points.isEmpty
        }
    }
}

public enum Geometry {
    public static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    public static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    public static func distance(_ p: CGPoint, segment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    /// Locks a direction to the nearest 45 degrees.
    public static func snapAngle(from origin: CGPoint, to p: CGPoint) -> CGPoint {
        let dx = p.x - origin.x, dy = p.y - origin.y
        let length = hypot(dx, dy)
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
    }

    /// Turns a drag into a square (or circle) anchored at `origin`.
    public static func squareCorner(from origin: CGPoint, to p: CGPoint) -> CGPoint {
        let dx = p.x - origin.x, dy = p.y - origin.y
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: origin.x + (dx < 0 ? -side : side), y: origin.y + (dy < 0 ? -side : side))
    }
}
