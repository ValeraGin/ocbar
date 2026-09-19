#!/usr/bin/env swift
//
// Иконка приложения: два сцепленных кольца на синем поле — туннель между
// двумя сетями. Тот же знак стоит в шапке меню (AppMark).
// Рисуется кодом, а не лежит картинкой в репозитории: бинарники в git
// стареют молча, а здесь видно, из чего иконка сделана.
//
//   swift make-icon.swift <каталог.iconset>

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

    // Поле: скруглённый квадрат по пропорциям системных иконок (поля ~10%).
    let inset = side * 0.09
    let rect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    // Системный синий, светлее сверху — как у иконок macOS.
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.25, green: 0.60, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.00, green: 0.38, blue: 0.87, alpha: 1),
    ])
    gradient?.draw(in: shape, angle: -90)

    // Знак: два кольца, сцепленные как звенья: сверху правое проходит над
    // левым, снизу — под ним. Где одно кольцо идёт поверх другого, под ним
    // прорезается полоса цветом поля — так видно, что кольца переплетены.
    let r = rect.width * 0.20, line = rect.width * 0.085
    let dx = r * 0.62
    let left = NSPoint(x: rect.midX - dx, y: rect.midY), right = NSPoint(x: rect.midX + dx, y: rect.midY)
    // Точки пересечения: у правого кольца — 180° ∓ α, у левого — ±α.
    let alpha = atan2(sqrt(r * r - dx * dx), dx) * 180 / .pi
    func arc(_ c: NSPoint, _ from: CGFloat, _ to: CGFloat, width: CGFloat = line) -> NSBezierPath {
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: r, startAngle: from, endAngle: to)
        p.lineWidth = width
        return p
    }
    func cut(_ c: NSPoint, _ from: CGFloat, _ to: CGFloat) {
        let band = arc(c, from, to).cgPath.copy(strokingWithWidth: line * 2.0, lineCap: .butt,
                                                lineJoin: .miter, miterLimit: 10)
        NSGraphicsContext.saveGraphicsState()
        ctx.addPath(band); ctx.clip()
        gradient?.draw(in: shape, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }
    NSColor.white.setStroke()
    arc(left, 0, 360).stroke()
    cut(right, 180 - alpha - 22, 180 - alpha + 22)
    NSColor.white.setStroke()
    arc(right, 0, 360).stroke()
    cut(left, -alpha - 22, -alpha + 22)
    NSColor.white.setStroke()
    arc(left, -alpha - 24, -alpha + 24).stroke()

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
