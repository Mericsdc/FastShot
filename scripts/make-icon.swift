// Draws the FastShot app icon at 1024 px: usage `swift scripts/make-icon.swift out.png`.
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

// Rounded tile with a deep blue → violet gradient.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.16, blue: 0.42, alpha: 1))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let gradient = CGGradient(colorsSpace: space, colors: [
    CGColor(srgbRed: 0.33, green: 0.20, blue: 0.93, alpha: 1),
    CGColor(srgbRed: 0.09, green: 0.47, blue: 1.00, alpha: 1),
    CGColor(srgbRed: 0.05, green: 0.78, blue: 0.95, alpha: 1),
] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.minY), end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])
// Soft highlight across the top.
let shine = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(shine, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY), options: [])
ctx.restoreGState()

// Viewfinder corners.
ctx.setStrokeColor(.white)
ctx.setLineWidth(46)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
let frame = CGRect(x: 250, y: 250, width: 524, height: 524)
let arm: CGFloat = 130
for (corner, dx, dy) in [(CGPoint(x: frame.minX, y: frame.minY), 1.0, 1.0), (CGPoint(x: frame.maxX, y: frame.minY), -1.0, 1.0),
                         (CGPoint(x: frame.minX, y: frame.maxY), 1.0, -1.0), (CGPoint(x: frame.maxX, y: frame.maxY), -1.0, -1.0)] {
    ctx.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
    ctx.addLine(to: corner)
    ctx.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
}
ctx.strokePath()

// Lightning bolt for "fast".
let bolt = CGMutablePath()
bolt.move(to: CGPoint(x: 560, y: 690))
bolt.addLine(to: CGPoint(x: 395, y: 490))
bolt.addLine(to: CGPoint(x: 498, y: 490))
bolt.addLine(to: CGPoint(x: 455, y: 330))
bolt.addLine(to: CGPoint(x: 630, y: 545))
bolt.addLine(to: CGPoint(x: 522, y: 545))
bolt.closeSubpath()
ctx.addPath(bolt)
ctx.setFillColor(CGColor(srgbRed: 1, green: 0.84, blue: 0.10, alpha: 1))
ctx.setLineWidth(18)
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.95, blue: 0.75, alpha: 1))
ctx.drawPath(using: .fillStroke)

// Red record dot.
ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.22, blue: 0.25, alpha: 1))
ctx.fillEllipse(in: CGRect(x: 618, y: 598, width: 96, height: 96))
ctx.setStrokeColor(.white)
ctx.setLineWidth(14)
ctx.strokeEllipse(in: CGRect(x: 618, y: 598, width: 96, height: 96))

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
