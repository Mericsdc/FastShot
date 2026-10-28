import AppKit
import CoreText

/// Draws annotations with Core Graphics. The same code paints the live canvas,
/// flattened screenshots and every exported video frame, so what you see while
/// editing is exactly what gets saved.
///
/// Every context handed to the renderer is y-down: canvas points, origin top-left.
public enum AnnotationRenderer {
    public static func font(size: Double, weight: NSFont.Weight = .semibold) -> CTFont {
        NSFont.systemFont(ofSize: CGFloat(size), weight: weight) as CTFont
    }

    public static func textPadding(fontSize: Double) -> CGSize {
        CGSize(width: ceil(fontSize * 0.4), height: ceil(fontSize * 0.2))
    }

    public static func textSize(_ text: String, fontSize: Double) -> CGSize {
        measure(text, font: font(size: fontSize))
    }

    public static func textBoxSize(_ text: String, fontSize: Double) -> CGSize {
        let size = textSize(text, fontSize: fontSize), pad = textPadding(fontSize: fontSize)
        return CGSize(width: size.width + pad.width * 2, height: size.height + pad.height * 2)
    }

    public static func draw(_ annotations: [Annotation], in ctx: CGContext, background: CGImage?, canvasSize: CGSize) {
        for annotation in annotations { draw(annotation, in: ctx, background: background, canvasSize: canvasSize) }
    }

    public static func draw(_ a: Annotation, in ctx: CGContext, background: CGImage?, canvasSize: CGSize) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let color = a.color.cgColor
        ctx.setLineWidth(a.strokeWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        switch a.kind {
        case .pen:
            ctx.addPath(smoothPath(a.points))
            ctx.strokePath()
        case .marker:
            ctx.setStrokeColor(a.color.withAlpha(0.42 * a.color.alpha).cgColor)
            ctx.addPath(smoothPath(a.points))
            ctx.strokePath()
        case .line:
            guard a.points.count >= 2 else { return }
            ctx.move(to: a.points[0])
            ctx.addLine(to: a.points[1])
            ctx.strokePath()
        case .arrow:
            drawArrow(a, in: ctx)
        case .rectangle:
            if a.filled { ctx.fill(a.box) } else {
                ctx.setLineJoin(.miter)
                ctx.stroke(a.box)
            }
        case .ellipse:
            if a.filled { ctx.fillEllipse(in: a.box) } else { ctx.strokeEllipse(in: a.box) }
        case .text:
            drawText(a, in: ctx)
        case .pixelate:
            drawPixelate(a, in: ctx, background: background, canvasSize: canvasSize)
        case .step:
            drawStep(a, in: ctx)
        }
    }

    /// Draws a CGImage upright into a y-down context.
    public static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    // MARK: Shapes

    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            // A zero-length segment with round caps paints a dot.
            path.addLine(to: first)
        } else if points.count == 2 {
            path.addLine(to: points[1])
        } else {
            for i in 1..<(points.count - 1) {
                let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
                path.addQuadCurve(to: mid, control: points[i])
            }
            path.addLine(to: points[points.count - 1])
        }
        return path
    }

    static func drawArrow(_ a: Annotation, in ctx: CGContext) {
        guard a.points.count >= 2 else { return }
        let start = a.points[0], end = a.points[1]
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }
        let ux = dx / length, uy = dy / length
        let head = min(length, a.arrowHeadLength)
        let halfWidth = head * 0.55
        let base = CGPoint(x: end.x - ux * head, y: end.y - uy * head)
        if length > head {
            // Stop the shaft inside the head so the round cap never pokes through the tip.
            ctx.move(to: start)
            ctx.addLine(to: CGPoint(x: end.x - ux * head * 0.6, y: end.y - uy * head * 0.6))
            ctx.strokePath()
        }
        ctx.move(to: end)
        ctx.addLine(to: CGPoint(x: base.x - uy * halfWidth, y: base.y + ux * halfWidth))
        ctx.addLine(to: CGPoint(x: base.x + uy * halfWidth, y: base.y - ux * halfWidth))
        ctx.closePath()
        ctx.setLineWidth(max(1, a.strokeWidth * 0.5))
        ctx.drawPath(using: .fillStroke)
    }

    static func drawText(_ a: Annotation, in ctx: CGContext) {
        let origin = a.points.first ?? .zero
        let pad = textPadding(fontSize: a.fontSize)
        let size = textSize(a.text, fontSize: a.fontSize)
        let box = CGRect(x: origin.x, y: origin.y, width: size.width + pad.width * 2, height: size.height + pad.height * 2)
        var ink = a.color
        if a.filled {
            let radius = min(box.height / 4, 10)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
            ink = a.color.contrasting
        }
        drawString(a.text, font: font(size: a.fontSize), color: ink.cgColor,
                   in: CGRect(x: origin.x + pad.width, y: origin.y + pad.height, width: size.width, height: size.height), ctx: ctx)
    }

    static func drawStep(_ a: Annotation, in ctx: CGContext) {
        let c = a.points.first ?? .zero, r = a.stepRadius
        let circle = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        ctx.fillEllipse(in: circle)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        ctx.setLineWidth(max(1.5, r * 0.12))
        ctx.strokeEllipse(in: circle.insetBy(dx: r * 0.06, dy: r * 0.06))
        let label = "\(a.number)"
        let labelFont = font(size: Double(r * 1.05), weight: .bold)
        let size = measure(label, font: labelFont)
        drawString(label, font: labelFont, color: a.color.contrasting.cgColor,
                   in: CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height), ctx: ctx)
    }

    static func drawPixelate(_ a: Annotation, in ctx: CGContext, background: CGImage?, canvasSize: CGSize) {
        let rect = a.box
        guard rect.width >= 1, rect.height >= 1 else { return }
        guard let background, canvasSize.width > 0, canvasSize.height > 0 else {
            // Nothing to sample (e.g. while recording live): show a neutral placeholder.
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 0.85))
            ctx.fill(rect)
            return
        }
        let sx = CGFloat(background.width) / canvasSize.width
        let sy = CGFloat(background.height) / canvasSize.height
        let imageBounds = CGRect(x: 0, y: 0, width: background.width, height: background.height)
        let pixelRect = CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy)
            .integral.intersection(imageBounds)
        guard !pixelRect.isNull, pixelRect.width >= 1, pixelRect.height >= 1,
              let crop = background.cropping(to: pixelRect) else { return }
        let block = CGFloat(4 + a.lineWidth * 2) * sx
        let columns = max(1, Int((pixelRect.width / block).rounded(.up)))
        let rows = max(1, Int((pixelRect.height / block).rounded(.up)))
        guard let small = CGContext(data: nil, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        small.interpolationQuality = .high
        small.draw(crop, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        guard let tiny = small.makeImage() else { return }
        ctx.interpolationQuality = .none
        drawImage(tiny, in: CGRect(x: pixelRect.minX / sx, y: pixelRect.minY / sy, width: pixelRect.width / sx, height: pixelRect.height / sy), ctx: ctx)
    }

    // MARK: Text

    static func attributed(_ string: String, font: CTFont, color: CGColor) -> CFAttributedString {
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
        return CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary)
    }

    static func measure(_ text: String, font: CTFont) -> CGSize {
        // An empty or newline-terminated string still occupies its last line.
        let sample = text.isEmpty || text.hasSuffix("\n") ? text + " " : text
        let setter = CTFramesetterCreateWithAttributedString(attributed(sample, font: font, color: CGColor.black))
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: 100_000, height: 100_000), nil)
        return CGSize(width: ceil(size.width) + 2, height: ceil(size.height) + 1)
    }

    static func drawString(_ string: String, font: CTFont, color: CGColor, in rect: CGRect, ctx: CGContext) {
        guard !string.isEmpty else { return }
        let setter = CTFramesetterCreateWithAttributedString(attributed(string, font: font, color: color))
        ctx.saveGState()
        // Core Text lays out y-up; flip locally so glyphs stand upright in our y-down space.
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }
}
