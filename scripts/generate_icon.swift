#!/usr/bin/env swift
// Native, deterministic icon generation. Run on macOS: swift scripts/generate_icon.swift
import CoreGraphics
import Foundation
import ImageIO

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

func color(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func rounded(_ context: CGContext, _ rect: CGRect, radius: CGFloat, fill: CGColor) {
    context.setFillColor(fill)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()
}

func circle(_ context: CGContext, _ center: CGPoint, radius: CGFloat, fill: CGColor) {
    context.setFillColor(fill)
    context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
}

func line(_ context: CGContext, _ points: [CGPoint], width: CGFloat, stroke: CGColor) {
    guard let first = points.first else { return }
    context.beginPath()
    context.move(to: first)
    for point in points.dropFirst() { context.addLine(to: point) }
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(stroke)
    context.strokePath()
}

func png(pixels: Int) throws -> Data {
    // 32-bit RGBX is a supported CoreGraphics bitmap format. A 24-bit AppKit
    // NSBitmapImageRep cannot reliably create a graphics context on CI runners.
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: pixels, height: pixels,
                                  bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                  space: space, bitmapInfo: bitmapInfo) else {
        throw NSError(domain: "IconGeneration", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot create RGBX context at \(pixels)px"])
    }
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    // SVG-style top-left origin keeps the native renderer and source SVG consistent.
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1, y: -1)
    let mint = color(0x159D79)
    context.setFillColor(color(0xF1F6F4))
    context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    rounded(context, CGRect(x: 196, y: 192, width: 632, height: 640), radius: 132, fill: mint)
    for top in [310.0, 492.0] {
        rounded(context, CGRect(x: 294, y: top, width: 436, height: 132), radius: 35, fill: color(0xFFFFFF))
        circle(context, CGPoint(x: 348, y: top + 66), radius: 17, fill: mint)
        circle(context, CGPoint(x: 668, y: top + 66), radius: 11, fill: color(0x93D7BE))
        line(context, [CGPoint(x: 404, y: top + 66), CGPoint(x: 508, y: top + 66)], width: 18, stroke: color(0xD4EAE2))
    }
    line(context, [CGPoint(x: 292, y: 724), CGPoint(x: 397, y: 724), CGPoint(x: 447, y: 660),
          CGPoint(x: 507, y: 762), CGPoint(x: 574, y: 674), CGPoint(x: 616, y: 724), CGPoint(x: 732, y: 724)],
         width: 22, stroke: color(0xFFFFFF))
    guard let image = context.makeImage() else {
        throw NSError(domain: "IconGeneration", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot create rendered image at \(pixels)px"])
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "IconGeneration", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot create PNG destination"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "IconGeneration", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot encode PNG at \(pixels)px"])
    }
    return data as Data
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
