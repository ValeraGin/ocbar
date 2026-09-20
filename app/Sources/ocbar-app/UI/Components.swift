import SwiftUI

// Строка-действие. В стиле .window у MenuBarExtra системного вида пунктов
// нет — рисуем сами: подсветка под курсором, тот же отступ, что у остальных
// строк.
struct MenuRow<Content: View>: View {
    var enabled: Bool = true
    let action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hover = false

    var body: some View {
        // Настоящая кнопка, а не HStack с onTapGesture: строку должно быть
        // видно VoiceOver и можно нажать с клавиатуры (⌃F7 — полный доступ
        // с клавиатуры). Вид тот же: своя подсветка под курсором и фокусом.
        Button(action: { if enabled { action() } }) {
            HStack(spacing: 8) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle(hover: hover && enabled))
        .disabled(!enabled)
        .onHover { hover = $0 }
        .padding(.horizontal, 5)
    }
}

/// Подсветка строки меню: под курсором, при нажатии и при фокусе клавиатуры.
private struct MenuRowStyle: ButtonStyle {
    let hover: Bool

    func makeBody(configuration: Configuration) -> some View {
        let lit = hover || configuration.isPressed
        return configuration.label
            .background(RoundedRectangle(cornerRadius: 5).fill(lit ? Color.accentColor.opacity(0.85) : .clear))
            .foregroundStyle(lit ? AnyShapeStyle(.white) : AnyShapeStyle(Palette.text))
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

// Строка «ключ — значение» в подробностях: подпись слева, моноширинное
// значение справа.
struct KVRow: View {
    var mono = true
    let label: String
    let value: String
    var color: Color = Palette.text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.secondary)
            Spacer(minLength: 8)
            // Несколько значений (резолверы) — по строке на каждое.
            Text(value.isEmpty ? "—" : value)
                .font(mono ? .ocMono : .system(size: 12)).foregroundStyle(color)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .lineLimit(value.contains("\n") ? nil : 1).truncationMode(.middle)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 2)
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

struct Sep: View {
    var body: some View {
        Rectangle().fill(Palette.line).frame(height: 1).padding(.vertical, 5)
    }
}

// Заголовок секции: подпись слева, счётчик справа.
struct SectionHead: View {
    let title: String
    var trailing: String = ""

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(Palette.secondary)
            Spacer()
            if !trailing.isEmpty {
                Text(trailing).font(.ocMonoSmall).foregroundStyle(Palette.tertiary)
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 2)
        .padding(.bottom, 1)
    }
}

// Список строк: пока строк немного — как есть, много — прокручивается внутри
// своей группы. Потолок считается по числу строк и их высоте, а не измерением
// содержимого: измерять высоту внутри прокрутки нельзя — прокрутка растягивает
// содержимое, и высота выходит то больше, то меньше нужной.
struct CappedRows<Content: View>: View {
    let count: Int
    var rowHeight: CGFloat = 34
    @ViewBuilder var content: () -> Content

    var body: some View {
        let limit = MenuView.rowsBeforeScroll
        if count <= limit {
            VStack(alignment: .leading, spacing: 0) { content() }
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) { content() }
            }
            .frame(height: CGFloat(limit) * rowHeight)
        }
    }
}

// Прокрутка с потолком: пока содержимое ниже потолка, занимает ровно
// столько, сколько ему нужно; выше — прокручивается. Обычный ScrollView в
// окне меню-бара либо растягивает меню до экрана, либо схлопывается.
struct BoundedScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: () -> Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            // fixedSize обязателен: без него прокрутка растягивает содержимое
            // до своей высоты, измеренная высота только росла, и меню,
            // вернувшись с «Сети и DNS», оставалось прежней высоты — с пустым
            // местом под значком.
            content()
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { g in
                    Color.clear.preference(key: HeightKey.self, value: g.size.height)
                })
        }
        .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
        .frame(height: min(max(contentHeight, 1), maxHeight))
    }

}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
        case .primary: (Palette.accent, .white)
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

// Плашка под карточкой состояния: одно предупреждение и его следующий шаг.
struct Banner: View {
    let color: Color
    let symbol: String
    let text: String
    var selectable = false
    var fix: (title: String, command: String)?
    var link: (String, () -> Void)?
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(color)
                .frame(width: 14).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if selectable { Text(text).textSelection(.enabled) } else { Text(text) }
                }
                .font(.system(size: 11.5)).foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(4)
                HStack(spacing: 12) {
                    if let fix {
                        Button(fix.title) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(fix.command, forType: .string)
                        }
                        .help(L("Скопировать: ") + fix.command)
                    }
                    if let link { Button(link.0, action: link.1) }
                }
                .buttonStyle(.link).font(.system(size: 11.5))
            }
            Spacer(minLength: 0)
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.borderless).foregroundStyle(Palette.tertiary)
                .accessibilityLabel(L("Скрыть"))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .groupBox(tint: color)
    }
}

// Значок строки: белый символ в цветном скруглённом квадрате, как в
// Системных настройках.
struct IconTile: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color))
            .accessibilityHidden(true)
    }
}

// Значок команды в подвале меню — без подложки, по центру своей колонки.
struct FooterIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).font(.system(size: 13)).frame(width: 20).opacity(0.75)
            .accessibilityHidden(true)
    }
}

// Заголовок группы: подпись слева, счётчик справа.
struct GroupHead: View {
    let title: String
    var trailing = ""
    var body: some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
            Spacer()
            Text(trailing).font(.system(size: 12)).foregroundStyle(Palette.tertiary)
        }
        .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 4)
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Palette.groupLine).frame(height: 1).padding(.leading, 12)
    }
}

// Значок и текст вплотную: у стандартной метки зазор рассчитан на меню.
struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}

// Знак ocbar — два сцепленных кольца на синем скруглённом квадрате. Рисуется
// кодом: у приложения, запущенного из сборки без бандла, своей иконки нет, и
// система подставила бы папку.
struct AppMark: View {
    var size: CGFloat = 22

    var body: some View {
        let ring = size * 0.36, line = max(1.5, size * 0.09)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.60, blue: 1.0),
                                              Color(red: 0.0, green: 0.38, blue: 0.87)],
                                     startPoint: .top, endPoint: .bottom))
            Circle().stroke(.white, lineWidth: line).frame(width: ring, height: ring).offset(x: -ring * 0.3)
            Circle().stroke(.white, lineWidth: line).frame(width: ring, height: ring).offset(x: ring * 0.3)
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
