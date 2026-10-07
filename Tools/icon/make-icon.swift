// Draws the Pitot app icon, a pixel-art set of three switches on a dark plate, and writes every macOS size into an asset catalog icon set.
// Run from the repository root:  swift Tools/icon/make-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset
// It uses CoreGraphics and ImageIO only, so the output is the same on every Mac.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

enum Palette {
    static let plateTop = color(0x26282E)
    static let plateBottom = color(0x0C0D10)
    static let art: [Character: CGColor] = [
        "O": color(0xD97757),
        "D": color(0x5F7285),
        "W": color(0xF2F6FA),
    ]
}

/// Three switches: two on (orange track, knob right) and one off (grey track, knob left).
let artGrid = [
    "................",
    "..........WWWW..",
    "..OOOOOOOOWWWW..",
    "..OOOOOOOOWWWW..",
    "..........WWWW..",
    "................",
    "..WWWW..........",
    "..WWWWDDDDDDDD..",
    "..WWWWDDDDDDDD..",
    "..WWWW..........",
    "................",
    "..........WWWW..",
    "..OOOOOOOOWWWW..",
    "..OOOOOOOOWWWW..",
    "..........WWWW..",
    "................",
]

/// Draws the icon into a square of `size` pixels. The plate follows the macOS icon grid (824 point rounded
/// square centered in 1024, corner radius 185) and may be antialiased. The art is drawn with whole pixel
/// squares, so it stays crisp at every size. At 16 pixels the plate fills the canvas so the art is not clipped.
func drawIcon(_ context: CGContext, size: Int) {
    let canvas = CGFloat(size)
    let unit = canvas / 1024
    let inset = size <= 16 ? 0 : CGFloat((Double(size) * 100 / 1024).rounded())
    let radius = size <= 16 ? 3 : 185 * unit
    let plate = CGRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)

    context.setShouldAntialias(true)
    context.saveGState()
    context.addPath(CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [Palette.plateTop, Palette.plateBottom] as CFArray,
        locations: [0, 1])
    {
        context.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])
    }
    context.restoreGState()

    context.setShouldAntialias(false)
    context.interpolationQuality = .none
    let cell = max(1, size * 40 / 1024)
    let offset = (size - artGrid.count * cell) / 2
    for (row, line) in artGrid.enumerated() {
        for (column, key) in line.enumerated() {
            guard let fill = Palette.art[key] else { continue }
            context.setFillColor(fill)
            context.fill(
                CGRect(
                    x: offset + column * cell, y: offset + (artGrid.count - 1 - row) * cell, width: cell, height: cell))
        }
    }
}

func writePNG(pixels: Int, to url: URL) throws {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw IconError.context }
    drawIcon(context, size: pixels)
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
