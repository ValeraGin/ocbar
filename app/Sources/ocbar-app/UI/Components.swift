import SwiftUI

// Нативный .link на macOS сохраняет системный синий вопреки tint.
// Общий стиль для текстовых команд с контрастным акцентом обеих тем.
struct BrandLinkStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Palette.accent)
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.6 : hover ? 0.8 : 1)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

struct StateDot: View {
    let color: Color
    var pulsing: Bool = false
    var size: CGFloat = 8
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(pulsing ? (on ? 0.35 : 1) : 1)
            .animation(pulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                       value: on)
            .onAppear { if pulsing { on = true } }
    }
}

// «Скопировать» — маленькая кнопка рядом со значением; после нажатия на
// секунду показывает галочку, чтобы было видно, что сработало.
struct CopyButton: View {
    let text: String
    @State private var done = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            done = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { done = false }
        } label: {
            Image(systemName: done ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(done ? Palette.ok : Palette.tertiary)
        }
        .buttonStyle(.borderless)
        .disabled(text.isEmpty)
        .help(L("Скопировать"))
    }
}

// Группа, как в сгруппированных формах macOS: спокойная подложка и тонкая
// обводка. С оттенком — для карточки, которая требует действия.
extension View {
    func groupBox(tint: Color? = nil) -> some View {
        background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(tint.map { $0.opacity(0.12) } ?? Palette.group))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(tint.map { $0.opacity(0.35) } ?? Palette.groupLine))
    }
}

// Главное действие меню — кнопка на всю ширину вместо выключателя: подпись
// говорит, что произойдёт, а не в каком положении рычажок.
struct WideButton: View {
    enum Kind { case primary, destructive, neutral }
    let title: String
    var systemImage: String?
    let kind: Kind
    var compact = false
    var hint: String?
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11)) }
                Text(title).font(.system(size: 13, weight: kind == .neutral ? .regular : .semibold))
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                if let hint { Text(hint).font(.system(size: 11)).opacity(0.55) }
            }
            .padding(.horizontal, 10)
            .frame(height: compact ? 26 : 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(WideButtonStyle(kind: kind, hover: hover && enabled))
        .disabled(!enabled)
        .onHover { hover = $0 }
        .accessibilityLabel(title)
    }
    @State private var hover = false
}

// Под курсором кнопка заметно меняется: подложка плотнее, обводка ярче —
// видно, на что сейчас нажмёшь.
private struct WideButtonStyle: ButtonStyle {
    let kind: WideButton.Kind
    let hover: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let (fill, text): (Color, Color) = switch kind {
        case .primary: (Palette.brand, Palette.onBrand)
        // «Отключить» — спокойная кнопка с красной подписью: в рабочем
        // состоянии главное на карточке — статус, а не выход из него.
        case .destructive: (hover ? Palette.bad.opacity(0.16) : Palette.group, Palette.bad)
        case .neutral: (hover ? Palette.text.opacity(0.14) : Palette.group, Palette.text)
        }
        let stroke: Color = switch kind {
        case .primary: hover ? .white.opacity(0.35) : .clear
        case .destructive: hover ? Palette.bad.opacity(0.5) : Palette.groupLine
        case .neutral: hover ? Palette.text.opacity(0.3) : Palette.groupLine
        }
        return configuration.label
            .foregroundStyle(text)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(stroke))
            .brightness(configuration.isPressed ? -0.1 : (hover && kind == .primary ? 0.08 : 0))
            .animation(.easeOut(duration: 0.1), value: hover)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

// Значок и текст вплотную: у стандартной метки зазор рассчитан на меню.
struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}

// Лаймовый свитч: один вход и два независимых маршрута.
// Геометрия соответствует website/dist/assets/icon.svg и make-icon.swift.
struct AppMark: View {
    var size: CGFloat = 22

    var body: some View {
        Canvas { context, bounds in
            context.scaleBy(x: bounds.width / 64, y: bounds.height / 64)
            let field = Path(roundedRect: CGRect(x: 2, y: 2, width: 60, height: 60), cornerRadius: 14)
            context.fill(field, with: .linearGradient(Gradient(colors: [
                Color(nsColor: NSColor(hex: "#303835")), Color(nsColor: NSColor(hex: "#151C19"))
            ]), startPoint: CGPoint(x: 10, y: 5), endPoint: CGPoint(x: 54, y: 62)))
            context.stroke(Path(roundedRect: CGRect(x: 2.5, y: 2.5, width: 59, height: 59), cornerRadius: 13.5),
                           with: .color(Color(nsColor: NSColor(hex: "#D6ECD5")).opacity(0.18)), lineWidth: 1)
            var lower = Path()
            lower.move(to: CGPoint(x: 29, y: 32)); lower.addLine(to: CGPoint(x: 42, y: 45)); lower.addLine(to: CGPoint(x: 48, y: 45))
            context.stroke(lower, with: .color(Color(nsColor: NSColor(hex: "#66746B"))), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            var upper = Path()
            upper.move(to: CGPoint(x: 15, y: 32)); upper.addLine(to: CGPoint(x: 29, y: 32))
            upper.addLine(to: CGPoint(x: 42, y: 19)); upper.addLine(to: CGPoint(x: 48, y: 19))
            context.stroke(upper, with: .linearGradient(Gradient(colors: [Color(nsColor: NSColor(hex: "#A4DA50")), Palette.brand]),
                           startPoint: CGPoint(x: 13, y: 32), endPoint: CGPoint(x: 49, y: 18)),
                           style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            for (x, y, color) in [(10.0, 27.0, Palette.brand), (44.0, 14.0, Palette.brand),
                                   (44.0, 40.0, Color(nsColor: NSColor(hex: "#819084")))] {
                context.fill(Path(roundedRect: CGRect(x: x, y: y, width: 10, height: 10), cornerRadius: 2), with: .color(color))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// Пояснение под группой формы — по левому краю: подвал сгруппированной формы
// macOS прижимает текст вправо, и длинная фраза читается плохо.
struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// Живой одноразовый код: сам код и сколько секунд он ещё годен. Код берётся
// у клиента из источника профиля заново, когда начинается новый период, —
// так видно, что сохранённый секрет верный, ещё до первого входа.
struct LiveTOTPCode: View {
    let profile: String
    let period: Int
    @State private var code: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let now = Int(ctx.date.timeIntervalSince1970)
            let left = period - now % period
            HStack(spacing: 8) {
                Text(Self.grouped(code ?? "······"))
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
                ProgressView(value: Double(left), total: Double(period))
                    .progressViewStyle(.circular).controlSize(.mini)
                Text(L("%@ с", "\(left)")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)
            }
            .task(id: now / max(1, period)) { await fetch() }
        }
        .accessibilityLabel(L("одноразовый код %@", code ?? "—"))
    }

    private func fetch() async {
        let name = profile
        let c = await Task.detached { OcbarClient.shared.totpCode(profile: name) }.value
        code = c
    }

    /// «482913» → «482 913»: так код легче сверять глазами.
    static func grouped(_ c: String) -> String {
        guard c.count == 6 || c.count == 8 else { return c }
        let mid = c.index(c.startIndex, offsetBy: c.count / 2)
        return c[..<mid] + " " + c[mid...]
    }
}
