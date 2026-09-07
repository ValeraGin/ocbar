import SwiftUI
import AppKit

// Цвета из песочницы (tools/ui-lab/index.html): один набор для светлой темы,
// один для тёмной. Фон панели не красим — его рисует система, и подменять
// системный материал своим прямоугольником в меню-баре не принято.
enum Palette {
    static let text      = dynamic(light: "#1c1c1a", dark: "#ecebe6")
    static let secondary = dynamic(light: "#5f5e5a", dark: "#a5a39c")
    static let tertiary  = dynamic(light: "#8a8880", dark: "#74736d")
    static let line      = dynamic(light: "#e2e0d8", dark: "#303036")
    static let line2     = dynamic(light: "#cfcdc4", dark: "#45454d")
    static let ok        = dynamic(light: "#1d7a52", dark: "#5dcaa5")
    static let warn      = dynamic(light: "#a56a0b", dark: "#efb14a")
    static let bad       = dynamic(light: "#b3352f", dark: "#ea7a72")
    static let accent    = dynamic(light: "#2f6bbf", dark: "#7fb0ee")

    static func dynamic(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

extension NSColor {
    convenience init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.hasPrefix("#") ? String(hex.dropFirst()) : hex).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                  green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255,
                  alpha: 1)
    }
}

extension Font {
    static let ocMono = Font.system(size: 11.5, design: .monospaced)
    static let ocMonoSmall = Font.system(size: 11, design: .monospaced)
    static let ocBody = Font.system(size: 13)
    static let ocNote = Font.system(size: 11.5)
    static let ocTitle = Font.system(size: 13, weight: .medium)
}
