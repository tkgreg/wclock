import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift Icon.swift output.icns")
}

let size = 1024
let colors = CGColorSpace(name: CGColorSpace.sRGB)!
let canvas = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: colors, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

let tile = CGRect(x: 80, y: 80, width: 864, height: 864)
let silhouette = CGPath(roundedRect: tile, cornerWidth: 193, cornerHeight: 193, transform: nil)

canvas.saveGState()
canvas.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: color(0, 0, 0, alpha: 0.38))
canvas.setFillColor(color(11, 12, 22))
canvas.addPath(silhouette)
canvas.fillPath()
canvas.restoreGState()

canvas.saveGState()
canvas.addPath(silhouette)
canvas.clip()
let gradient = CGGradient(colorsSpace: colors, colors: [color(31, 37, 58), color(11, 12, 22)] as CFArray, locations: [0, 1])!
canvas.drawLinearGradient(gradient, start: CGPoint(x: 204, y: 944), end: CGPoint(x: 820, y: 80), options: [])
canvas.restoreGState()

canvas.addPath(silhouette)
canvas.setStrokeColor(color(134, 167, 223, alpha: 0.3))
canvas.setLineWidth(4)
canvas.strokePath()

let globe = ["0011100", "0101010", "1010101", "1111111", "1010101", "0101010", "0011100"]
let pitch: CGFloat = 87
let dot: CGFloat = 57
canvas.setFillColor(color(130, 251, 156))
for (row, pattern) in globe.enumerated() {
    for (column, cell) in pattern.enumerated() where cell == "1" {
        let x = 512 + CGFloat(column - 3) * pitch - dot / 2
        let y = 512 - CGFloat(row - 3) * pitch - dot / 2
        canvas.fillEllipse(in: CGRect(x: x, y: y, width: dot, height: dot))
    }
}

let artwork = canvas.makeImage()!

func sizeField(_ value: Int) -> Data {
    var bytes = UInt32(value).bigEndian
    return withUnsafeBytes(of: &bytes) { Data($0) }
}

var representations = Data()
for (type, pixels) in [
    ("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128),
    ("ic08", 256), ("ic09", 512), ("ic10", 1024),
] {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: colors, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(artwork, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let buffer = NSMutableData()
    let writer = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(writer, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(writer) else { fatalError("Could not encode icon image") }
    representations.append(contentsOf: type.utf8)
    representations.append(sizeField(buffer.length + 8))
    representations.append(buffer as Data)
}

var icon = Data("icns".utf8)
icon.append(sizeField(representations.count + 8))
icon.append(representations)
try icon.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
