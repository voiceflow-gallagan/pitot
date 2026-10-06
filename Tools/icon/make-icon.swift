// Draws the Pitot app icon, a flat gauge dial, and writes every macOS size into an asset catalog icon set.
// Run from the repository root:  swift Tools/icon/make-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset
// It uses CoreGraphics and ImageIO only, so the output is the same on every Mac.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Palette {
    static let background = CGColor(srgbRed: 0.09, green: 0.20, blue: 0.33, alpha: 1)
    static let face = CGColor(srgbRed: 0.13, green: 0.29, blue: 0.45, alpha: 1)
    static let scale = CGColor(srgbRed: 0.93, green: 0.95, blue: 0.97, alpha: 1)
    static let caution = CGColor(srgbRed: 0.96, green: 0.55, blue: 0.16, alpha: 1)
    static let needle = CGColor(srgbRed: 0.96, green: 0.55, blue: 0.16, alpha: 1)
}

/// Draws the icon into a square of `size` pixels. Small sizes drop the minor ticks, and the 16 pixel size
/// drops all ticks and thickens the rest, so the mark stays legible.
func drawIcon(_ context: CGContext, size: CGFloat) {
    let unit = size / 1024
    // The macOS icon grid: an 824 point rounded square centered in 1024, corner radius 185.
    let inset = 100 * unit
    let plate = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    context.addPath(CGPath(roundedRect: plate, cornerWidth: 185 * unit, cornerHeight: 185 * unit, transform: nil))
    context.setFillColor(Palette.background)
    context.fillPath()

    let center = CGPoint(x: size / 2, y: size / 2 - 20 * unit)
    let radius = 300 * unit
    let faceRadius = radius + 40 * unit
    context.addEllipse(in: CGRect(x: center.x - faceRadius, y: center.y - faceRadius, width: 2 * faceRadius, height: 2 * faceRadius))
    context.setFillColor(Palette.face)
    context.fillPath()

    // The scale runs over 240 degrees, from lower left to lower right through the top.
    let start = CGFloat.pi * 1.25
    let sweep = CGFloat.pi * 1.5
    let small = size <= 64
    let tiny = size <= 16
    context.setLineCap(.round)

    context.setStrokeColor(Palette.scale)
    context.setLineWidth((tiny ? 80 : small ? 34 : 26) * unit)
    context.addArc(center: center, radius: radius, startAngle: start, endAngle: start - sweep * 0.78, clockwise: true)
    context.strokePath()
    context.setStrokeColor(Palette.caution)
    context.addArc(center: center, radius: radius, startAngle: start - sweep * 0.82, endAngle: start - sweep, clockwise: true)
    context.strokePath()

    let ticks = tiny ? 0 : small ? 4 : 12
    for index in 0...ticks where !tiny {
        let fraction = CGFloat(index) / CGFloat(ticks)
        let angle = start - sweep * fraction
        let major = small || index % 3 == 0
        let outer = radius - 50 * unit
        let inner = outer - (major ? 70 : 38) * unit
        context.setStrokeColor(Palette.scale)
        context.setLineWidth((major ? (small ? 30 : 20) : 12) * unit)
        context.move(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
        context.addLine(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
        context.strokePath()
    }

    // The needle points two thirds up the scale.
    let needleAngle = start - sweep * 0.66
    let tip = CGPoint(x: center.x + cos(needleAngle) * (radius - 70 * unit), y: center.y + sin(needleAngle) * (radius - 70 * unit))
    let side = needleAngle + CGFloat.pi / 2
    let halfWidth = (tiny ? 60 : small ? 30 : 22) * unit
    context.setFillColor(Palette.needle)
    context.move(to: tip)
    context.addLine(to: CGPoint(x: center.x + cos(side) * halfWidth, y: center.y + sin(side) * halfWidth))
    context.addLine(to: CGPoint(x: center.x - cos(side) * halfWidth, y: center.y - sin(side) * halfWidth))
    context.closePath()
    context.fillPath()

    let hub = (tiny ? 95 : small ? 62 : 52) * unit
    context.addEllipse(in: CGRect(x: center.x - hub, y: center.y - hub, width: 2 * hub, height: 2 * hub))
    context.setFillColor(Palette.needle)
    context.fillPath()
    let dot = hub * 0.45
    context.addEllipse(in: CGRect(x: center.x - dot, y: center.y - dot, width: 2 * dot, height: 2 * dot))
    context.setFillColor(Palette.background)
    context.fillPath()
}

func writePNG(pixels: Int, to url: URL) throws {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw IconError.context }
    context.setShouldAntialias(true)
    drawIcon(context, size: CGFloat(pixels))
    guard let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw IconError.encode(url.path) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw IconError.encode(url.path) }
}

enum IconError: Error {
    case context
    case encode(String)
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift <AppIcon.appiconset folder>\n".utf8))
    exit(2)
}
let folder = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try writePNG(pixels: points * scale, to: folder.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: folder.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon sizes to \(folder.path)")
