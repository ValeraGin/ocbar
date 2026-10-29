import SwiftUI

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
        Text(text).font(.system(size: 12)).foregroundStyle(Palette.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Keep the summary compact while making the complete diagnostic readable/copyable.
struct ExpandableMessage: View {
    let text: String
    var summary: String? = nil
    var color: Color = .primary
    @State private var expanded = CommandLine.arguments.contains("--stage")
        && CommandLine.arguments.contains("--expand-message")

    static func needsDisclosure(_ text: String) -> Bool {
        text.count > 160 || text.components(separatedBy: .newlines).count > 3
    }
    private var canExpand: Bool { Self.needsDisclosure(text) || (summary.map { $0 != text } ?? false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if expanded && canExpand {
                ScrollView {
                    Text(text).foregroundStyle(color).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(height: 140)
            } else {
                Text(summary ?? text).lineLimit(canExpand ? 3 : nil)
                    .foregroundStyle(color).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if canExpand {
                Button(expanded ? L("Свернуть") : L("Показать полностью")) { expanded.toggle() }
                    .buttonStyle(.link)
            }
        }
        .onChange(of: text) { _, _ in expanded = false }
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
        let c = await Task.detached { OCMacClient.shared.totpCode(profile: name) }.value
        code = c
    }

    /// «482913» → «482 913»: так код легче сверять глазами.
    static func grouped(_ c: String) -> String {
        guard c.count == 6 || c.count == 8 else { return c }
        let mid = c.index(c.startIndex, offsetBy: c.count / 2)
        return c[..<mid] + " " + c[mid...]
    }
}
