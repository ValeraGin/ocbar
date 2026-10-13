#!/usr/bin/env swift
//
// Лаймовый свитч на графите. Та же геометрия в AppMark и website/next/assets/icon.svg.
// swift make-icon.swift <каталог.iconset>

import AppKit

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func icon(_ px: Int) -> Data? {
    let side = CGFloat(px)
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    defer { image.unlockFocus() }
    guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }
    ctx.setShouldAntialias(true)
    ctx.saveGState()

    // Иконка macOS с полями 9%; внутренние координаты как у SVG 64 × 64.
    ctx.translateBy(x: side * 0.09, y: side * 0.91)
    ctx.scaleBy(x: side * 0.82 / 60, y: -side * 0.82 / 60)
    ctx.translateBy(x: -2, y: -2)
    func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
    let field = NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 60, height: 60), xRadius: 14, yRadius: 14)
    NSGraphicsContext.saveGraphicsState()
    field.addClip()
    NSGradient(colors: [rgb(0x303835), rgb(0x151C19)])?.draw(from: NSPoint(x: 10, y: 5), to: NSPoint(x: 54, y: 62), options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
    NSGraphicsContext.restoreGraphicsState()
    rgb(0xD6ECD5, alpha: 0.18).setStroke()
    let border = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 2.5, width: 59, height: 59), xRadius: 13.5, yRadius: 13.5)
    border.lineWidth = 1; border.stroke()
    func route(_ points: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: points[0]); for point in points.dropFirst() { path.line(to: point) }
        path.lineWidth = 5; path.lineCapStyle = .round; path.lineJoinStyle = .round
        return path
    }
    rgb(0x66746B).setStroke()
    route([NSPoint(x: 29, y: 32), NSPoint(x: 42, y: 45), NSPoint(x: 48, y: 45)]).stroke()
    let upper = route([NSPoint(x: 15, y: 32), NSPoint(x: 29, y: 32), NSPoint(x: 42, y: 19), NSPoint(x: 48, y: 19)])
    NSGraphicsContext.saveGraphicsState()
    ctx.addPath(upper.cgPath.copy(strokingWithWidth: 5, lineCap: .round, lineJoin: .round, miterLimit: 10)); ctx.clip()
    NSGradient(colors: [rgb(0xA4DA50), rgb(0xC3F36B)])?.draw(from: NSPoint(x: 13, y: 32), to: NSPoint(x: 49, y: 18), options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
    NSGraphicsContext.restoreGraphicsState()
    for (x, y, hex): (CGFloat, CGFloat, UInt32) in [(10, 27, 0xC3F36B), (44, 14, 0xC3F36B), (44, 40, 0x819084)] {
        rgb(hex).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 10, height: 10), xRadius: 2, yRadius: 2).fill()
    }
    ctx.restoreGState()

    guard let rep = NSBitmapImageRep(focusedViewRect: NSRect(x: 0, y: 0, width: side, height: side))
    else { return nil }
    return rep.representation(using: .png, properties: [:])
}

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("использование: make-icon.swift <каталог.iconset>\n".utf8))
    exit(2)
}
let dir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (name, px) in sizes {
    guard let data = icon(px) else {
        FileHandle.standardError.write(Data("не нарисовалось: \(name)\n".utf8)); exit(1)
    }
    try? data.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
}
print("иконки: \(dir)")
