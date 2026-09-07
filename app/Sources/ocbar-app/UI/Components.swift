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
        HStack(spacing: 8) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hover && enabled ? Color.accentColor.opacity(0.85) : .clear)
            )
            .foregroundStyle(hover && enabled ? AnyShapeStyle(.white) : AnyShapeStyle(Palette.text))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { if enabled { action() } }
            .opacity(enabled ? 1 : 0.45)
            .padding(.horizontal, 5)
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
