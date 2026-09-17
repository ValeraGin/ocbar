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
    let label: String
    let value: String
    var color: Color = Palette.text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.secondary)
            Spacer(minLength: 8)
            Text(value.isEmpty ? "—" : value)
                .font(.ocMono).foregroundStyle(color)
                .textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 2)
    }
}

struct StateDot: View {
    let color: Color
    var pulsing: Bool = false
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
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

// Прокрутка с потолком: пока содержимое ниже потолка, занимает ровно
// столько, сколько ему нужно; выше — прокручивается. Обычный ScrollView в
// окне меню-бара либо растягивает меню до экрана, либо схлопывается.
struct BoundedScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: () -> Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            content()
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
        .help("Скопировать")
    }
}
