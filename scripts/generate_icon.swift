#!/usr/bin/env swift
// Native, deterministic icon generation. Run on macOS: swift scripts/generate_icon.swift
import AppKit
import Foundation

struct IconSize {
    let idiom: String
    let points: Double
    let scale: Int
    var pixels: Int { Int(points * Double(scale)) }
    var filename: String { "icon-\(idiom)-\(points)-\(scale)x.png" }
    var pointString: String { points.rounded() == points ? String(Int(points)) : String(points) }
}

let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("ServerMonitor/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let sizes: [IconSize] = [
    .init(idiom: "iphone", points: 20, scale: 2), .init(idiom: "iphone", points: 20, scale: 3),
    .init(idiom: "iphone", points: 29, scale: 2), .init(idiom: "iphone", points: 29, scale: 3),
    .init(idiom: "iphone", points: 40, scale: 2), .init(idiom: "iphone", points: 40, scale: 3),
    .init(idiom: "iphone", points: 60, scale: 2), .init(idiom: "iphone", points: 60, scale: 3),
    .init(idiom: "ipad", points: 20, scale: 1), .init(idiom: "ipad", points: 20, scale: 2),
    .init(idiom: "ipad", points: 29, scale: 1), .init(idiom: "ipad", points: 29, scale: 2),
    .init(idiom: "ipad", points: 40, scale: 1), .init(idiom: "ipad", points: 40, scale: 2),
    .init(idiom: "ipad", points: 76, scale: 1), .init(idiom: "ipad", points: 76, scale: 2),
    .init(idiom: "ipad", points: 83.5, scale: 2), .init(idiom: "ios-marketing", points: 1024, scale: 1)
]

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func rounded(_ rect: CGRect, radius: CGFloat, fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func circle(_ center: CGPoint, radius: CGFloat, fill: NSColor) {
    fill.setFill()
    NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
}

func line(_ points: [CGPoint], width: CGFloat, stroke: NSColor) {
    guard let first = points.first else { return }
    let path = NSBezierPath()
    path.move(to: first)
    for point in points.dropFirst() { path.line(to: point) }
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    stroke.setStroke()
    path.stroke()
}

func png(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                        bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "IconGeneration", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    // SVG-style top-left origin keeps the native renderer and source SVG consistent.
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1, y: -1)
    let mint = color(0x159D79)
    color(0xF1F6F4).setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
    rounded(CGRect(x: 196, y: 192, width: 632, height: 640), radius: 132, fill: mint)
    for top in [310.0, 492.0] {
        rounded(CGRect(x: 294, y: top, width: 436, height: 132), radius: 35, fill: .white)
        circle(CGPoint(x: 348, y: top + 66), radius: 17, fill: mint)
        circle(CGPoint(x: 668, y: top + 66), radius: 11, fill: color(0x93D7BE))
        line([CGPoint(x: 404, y: top + 66), CGPoint(x: 508, y: top + 66)], width: 18, stroke: color(0xD4EAE2))
    }
    line([CGPoint(x: 292, y: 724), CGPoint(x: 397, y: 724), CGPoint(x: 447, y: 660),
          CGPoint(x: 507, y: 762), CGPoint(x: 574, y: 674), CGPoint(x: 616, y: 724), CGPoint(x: 732, y: 724)],
         width: 22, stroke: .white)
    graphics.flushGraphics()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGeneration", code: 2)
    }
    return data
}

var images: [[String: String]] = []
for icon in sizes {
    try png(pixels: icon.pixels).write(to: output.appendingPathComponent(icon.filename))
    images.append(["idiom": icon.idiom, "size": "\(icon.pointString)x\(icon.pointString)",
                   "scale": "\(icon.scale)x", "filename": icon.filename])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
let catalog: [String: Any] = ["info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.deletingLastPathComponent().appendingPathComponent("Contents.json"))
print("Generated \(sizes.count) icons in \(output.path)")
