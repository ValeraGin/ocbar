import SwiftUI
import AppKit

// Цвета из песочницы (tools/ui-lab/index.html): один набор для светлой темы,
// один для тёмной. У меню непрозрачная подложка: системный материал над
// белым окном высветляет фон, не меняя наши цвета текста вместе с ним.
enum Palette {
    static let menuSurface = dynamic(light: "#f6f6f7", dark: "#232326")
    static let text      = dynamic(light: "#1c1c1a", dark: "#ecebe6")
    static let secondary = dynamic(light: "#5f5e5a", dark: "#a5a39c")
    static let tertiary  = dynamic(light: "#686660", dark: "#a3a19b")
    static let line      = dynamic(light: "#e2e0d8", dark: "#303036")
    static let line2     = dynamic(light: "#cfcdc4", dark: "#45454d")
    // Цвета состояний независимы от бренда: предупреждение остаётся оранжевым.
    static let ok        = dynamic(light: "#248a3d", dark: "#30d158")
    static let warn      = dynamic(light: "#c56a00", dark: "#ff9f0a")
    static let bad       = dynamic(light: "#d70015", dark: "#ff453a")
    // Лайм — заливка с тёмной подписью. На светлом фоне ссылки темнее.
    static let brand     = Color(nsColor: NSColor(hex: "#C3F36B"))
    static let onBrand   = Color(nsColor: NSColor(hex: "#182018"))
    static let accent    = dynamic(light: "#49691e", dark: "#C3F36B")
    // Нативные контролы рисуют белые галочки: их заливка должна быть темнее.
    static let control   = Color(nsColor: NSColor(hex: "#527525"))
    static let violet    = dynamic(light: "#8944ab", dark: "#bf5af2")
    // Подложка групп и их обводка — как у сгруппированных форм.
    static let group     = dynamic(light: "#00000008", dark: "#ffffff0d")
    static let groupLine = dynamic(light: "#0000000f", dark: "#ffffff14")

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
        let raw = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        // #rrggbbaa — с прозрачностью, #rrggbb — непрозрачный.
        let rgba = raw.count == 8 ? v : (v << 8) | 0xff
        self.init(srgbRed: CGFloat((rgba >> 24) & 0xff) / 255,
                  green: CGFloat((rgba >> 16) & 0xff) / 255,
                  blue: CGFloat((rgba >> 8) & 0xff) / 255,
                  alpha: CGFloat(rgba & 0xff) / 255)
    }
}

extension Font {
    static let ocMono = Font.system(size: 11.5, design: .monospaced)
    static let ocMonoSmall = Font.system(size: 11, design: .monospaced)
    static let ocBody = Font.system(size: 13)
    static let ocNote = Font.system(size: 11.5)
    static let ocTitle = Font.system(size: 13, weight: .medium)
}
