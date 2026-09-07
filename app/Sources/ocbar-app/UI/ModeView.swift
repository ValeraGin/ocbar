import SwiftUI

// Экран выбора режима. Прокси-режима в клиенте пока нет: здесь только
// переключатель и объяснение, чем режимы отличаются. Пока ocbar не умеет
// вторую ветку запуска, выбор ничего не меняет — и об этом сказано прямо,
// а не подразумевается.
struct ModeView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case tunnel, proxy
        var id: String { rawValue }
        var title: String { self == .tunnel ? "Туннель" : "Прокси (SOCKS)" }
    }

    @State private var mode: Mode = .tunnel
    @State private var systemProxy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Как пускать трафик")
                    .font(.system(size: 15, weight: .medium))

                HStack(alignment: .top, spacing: 12) {
                    card(.tunnel,
                         summary: "Сетевой интерфейс utun и маршруты из профиля.",
                         points: [
                            ("plus", "Работают любые программы, ничего настраивать не нужно"),
                            ("plus", "Split DNS через /etc/resolver — внутренние имена резолвятся"),
                            ("minus", "Меняет таблицу маршрутов, поэтому нужны права root — их даёт хелпер"),
                         ],
                         active: true)
                    card(.proxy,
                         summary: "openconnect --script-tun отдаёт поток ocproxy; тот поднимает локальный SOCKS.",
                         points: [
                            ("plus", "Маршруты и системные настройки не трогаются вовсе — права не нужны"),
                            ("plus", "Домашняя сеть и лаборатория гарантированно не задеты"),
                            ("minus", "Работает только то, что умеет ходить через SOCKS"),
                            ("minus", "В ocbar пока не реализовано — нужна вторая ветка запуска"),
                         ],
                         active: false)
                }

                note(mode == .tunnel
                     ? "Сейчас работает туннельный режим — так клиент подключается сегодня."
                     : "Прокси-режим ещё не реализован в ocbar: выбор здесь ничего не меняет. Нужны запуск с --script-tun, ocproxy из Homebrew, своё состояние и своя проверка живости.")

                Divider()

                Text("Системный прокси").font(.system(size: 13, weight: .medium))
                Toggle("Включать SOCKS для активного сетевого сервиса при подключении", isOn: $systemProxy)
                    .disabled(true)
                VStack(alignment: .leading, spacing: 4) {
                    bullet("Запись требует прав администратора: networksetup -setsocksfirewallproxy — значит через привилегированный хелпер, отдельной подкомандой со строгой проверкой аргументов.")
                    bullet("Снимать настройку при отключении обязательно: иначе система останется с мёртвым прокси и без сети.")
                    bullet("На этой машине уже есть свой SOCKS на порту 10808 от стороннего приложения — чужие настройки перезаписывать нельзя.")
                    bullet("Пока не реализовано: переключатель показан, чтобы обсуждать форму, а не чтобы им пользоваться.")
                }
            }
            .padding(18)
        }
        .frame(minWidth: 640, minHeight: 460)
    }

    private func card(_ value: Mode, summary: String, points: [(String, String)], active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: mode == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(mode == value ? Palette.accent : Palette.line2)
                Text(value.title).font(.system(size: 13, weight: .medium))
                if active {
                    Text("работает").font(.system(size: 10))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Palette.ok.opacity(0.18)))
                        .foregroundStyle(Palette.ok)
                } else {
                    Text("в планах").font(.system(size: 10))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Palette.warn.opacity(0.18)))
                        .foregroundStyle(Palette.warn)
                }
            }
            Text(summary).font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(points, id: \.1) { kind, text in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: kind == "plus" ? "plus.circle" : "minus.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(kind == "plus" ? Palette.ok : Palette.tertiary)
                        Text(text).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor).opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(mode == value ? Palette.accent : Palette.line, lineWidth: mode == value ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { mode = value }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.warn.opacity(0.12)))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("·").foregroundStyle(Palette.tertiary)
            Text(text).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
