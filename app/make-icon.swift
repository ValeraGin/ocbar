#!/usr/bin/env swift
//
// Иконка приложения: монограмма «oc» на синем поле — тот же знак, что в
// меню-баре, чтобы приложение узнавалось и в Finder, и в переключателе.
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
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.20, green: 0.44, blue: 0.78, alpha: 1),
        NSColor(srgbRed: 0.11, green: 0.26, blue: 0.52, alpha: 1),
    ])
    gradient?.draw(in: shape, angle: -90)

    // Знак: та же монограмма «oc», что в строке состояния.
    let base = NSFont.systemFont(ofSize: side * 0.58, weight: .heavy)
    let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: side * 0.58) } ?? base
    let text = NSAttributedString(string: "oc", attributes: [
        .font: font, .foregroundColor: NSColor.white, .kern: -side * 0.03,
    ])
    let size = text.size()
    text.draw(at: NSPoint(x: (side - size.width) / 2, y: (side - size.height) / 2 - side * 0.02))

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
