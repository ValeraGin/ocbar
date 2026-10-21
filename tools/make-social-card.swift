import AppKit
// Карточка для ссылок 1200×630: заголовок лендинга и настоящее меню.
//   swift tools/make-social-card.swift <en|ru> <menu.png> <out-без-расширения>
// Обычно её зовёт tools/social-card.sh: он же снимает меню из витрины.
let args = CommandLine.arguments
guard args.count == 4 else { print("usage: make-social-card.swift <en|ru> <menu.png> <out>"); exit(2) }
let (lang, menuPath, out) = (args[1], args[2], args[3])
let text: [String: (String, String, String)] = [
    "en": ("Same AnyConnect VPN.", "Your rules.", "Open-source client for macOS · built on OpenConnect"),
    "ru": ("Тот же AnyConnect.", "Твои правила.", "Открытый клиент для macOS · на основе OpenConnect"),
]
guard let (first, second, footer) = text[lang], let menu = NSImage(contentsOfFile: menuPath) else { exit(2) }
let size = NSSize(width: 1200, height: 630)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 630, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func label(_ s: String, _ x: CGFloat, _ y: CGFloat, _ font: NSFont, _ c: NSColor) {
    (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: c])
}
// Фон — как у страницы и анимации, чтобы карточка и сайт были одним целым.
color(0xEEF0EA).setFill(); NSRect(origin: .zero, size: size).fill()
let ink = color(0x17201D), muted = color(0x56605A)
NSImage(contentsOfFile: "app/Resources/AppIcon.icns")!.draw(in: NSRect(x: 62, y: 500, width: 76, height: 76))
label("ocbar", 150, 517, .systemFont(ofSize: 38, weight: .semibold), ink)
let headline = NSFont.systemFont(ofSize: 62, weight: .bold)
label(first, 66, 330, headline, ink)
label(second, 66, 252, headline, ink)
color(0xC3F36B).setFill()
NSBezierPath(roundedRect: NSRect(x: 70, y: 214, width: 120, height: 12), xRadius: 6, yRadius: 6).fill()
label(footer, 70, 70, .systemFont(ofSize: 22, weight: .regular), muted)
// Меню справа, прижато к верхнему краю, как в строке меню: по высоте карточки с
// полями, но не шире правой колонки — заголовок слева не перекрывается.
let scale = min(520 / menu.size.height, 400 / menu.size.width)
let height = menu.size.height * scale, width = menu.size.width * scale
menu.draw(in: NSRect(x: 1200 - 56 - width, y: 630 - 56 - height, width: width, height: height))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out + ".png"))
try rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])!.write(to: URL(fileURLWithPath: out + ".jpg"))
