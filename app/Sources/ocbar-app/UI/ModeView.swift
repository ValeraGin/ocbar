import SwiftUI

// Экран режима: как профиль пускает трафик — интерфейсом и маршрутами или
// локальным SOCKS. Выбор живёт в самом профиле (`[Connection] Mode`), а не
// в настройках приложения: профиль описывает подключение целиком, и файл,
// отданный коллеге, должен подключаться так же.
//
// Оба режима работают (docs/09-proxy-mode.md). Прокси-режиму нужен ocproxy
// из Homebrew — он не зависимость формулы, а проверка при запуске.
struct ModeView: View {
    @State private var files: [String] = []
    @State private var selected: String = ""
    @State private var doc = ProfileDoc()
    @State private var message: String?
    @State private var messageIsError = false
    @State private var dirty = false
    // Есть ли ocproxy — из `ocbar version --all`, в фоне: вызов бывает
    // долгим, а считался прямо при отрисовке, на главном потоке.
    @State private var ocproxy: Bool?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if files.isEmpty { noProfiles } else { editor }
            }
            .padding(18)
        }
        .frame(minWidth: 640, minHeight: 460)
        .onAppear { reload(); loadVersions() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Как пускать трафик").font(.system(size: 15, weight: .medium))
            Text("Свойство профиля: одно подключение — один режим. Смена режима — это новое подключение, а не переключатель на живой сессии.")
                .font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var noProfiles: some View {
        Text("Режим хранится в файле-профиле (.ocbar), а таких файлов пока нет. На вкладке «Профили» можно перевести профиль из profiles.conf в файл — одной кнопкой, командой самого клиента.")
            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.warn.opacity(0.12)))
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("Профиль").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                Picker("", selection: $selected) {
                    ForEach(files, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 220)
                .onChange(of: selected) { _ in load() }
                Spacer()
            }

            HStack(alignment: .top, spacing: 12) {
                card("tunnel", "Туннель",
                     summary: "Сетевой интерфейс utun и маршруты из профиля.",
                     points: [
                        (true, "Работают любые программы, настраивать нечего"),
                        (true, "Split DNS через /etc/resolver — внутренние имена резолвятся"),
                        (false, "Меняет таблицу маршрутов, поэтому нужен root — его даёт хелпер"),
                     ],
                     badge: ("работает", Palette.ok))
                card("proxy", "Прокси (SOCKS)",
                     summary: "openconnect --script-tun отдаёт поток ocproxy, тот поднимает локальный SOCKS.",
                     points: [
                        (true, "Маршруты и системные настройки не трогаются — права не нужны"),
                        (true, "Домашняя сеть и лаборатория не задеты в принципе"),
                        (false, "Работает только то, что умеет ходить через SOCKS"),
                        (false, "Нужен ocproxy: brew install ocproxy"),
                     ],
                     badge: ocproxyBadge)
            }

            if doc.mode == "proxy", ocproxy == false {
                note("ocproxy на этой машине не найден — подключение в прокси-режиме откажет, пока его нет: brew install ocproxy. В формулу он не входит: нужен только этому режиму.")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Локальный SOCKS").font(.system(size: 13, weight: .medium))
                HStack(spacing: 8) {
                    Text("Порт").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    TextField("11080", text: $doc.proxyPort)
                        .textFieldStyle(.roundedBorder).font(.ocMono).frame(width: 90)
                        .onChange(of: doc.proxyPort) { _ in dirty = true; message = nil }
                    if doc.proxyPort.trimmed == "10808" {
                        Text("занят сторонним SOCKS на этой машине")
                            .font(.ocNote).foregroundStyle(Palette.warn)
                    }
                    Spacer()
                }
                Toggle("Включать системный SOCKS вместе с подключением", isOn: $doc.systemProxy)
                    .onChange(of: doc.systemProxy) { _ in dirty = true; message = nil }
                VStack(alignment: .leading, spacing: 4) {
                    bullet("Без галочки система не трогается вовсе: SOCKS указывают тем программам, которым он нужен (ALL_PROXY, настройки браузера).")
                    bullet("С галочкой прокси ставится на активный сетевой сервис через привилегированный хелпер и снимается при отключении — иначе система осталась бы с мёртвым прокси и без сети.")
                    bullet("Если на сервисе уже стоит чужой SOCKS (на этой машине — 127.0.0.1:10808), хелпер откажется и скажет, что там стоит. Чужие настройки не перезаписываются; подключение при этом состоится, а меню покажет причину.")
                    bullet("Снимается при отключении, при уборке и супервизором, если прокси умер: иначе система осталась бы с мёртвым прокси и без сети.")
                }
            }

            HStack(spacing: 10) {
                if let message {
                    Text(message).font(.system(size: 11))
                        .foregroundStyle(messageIsError ? Palette.bad : Palette.ok)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Сохранить в профиль") { save() }.disabled(!dirty)
            }
        }
    }

    private func card(_ value: String, _ title: String, summary: String,
                      points: [(Bool, String)], badge: (String, Color)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: doc.mode == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(doc.mode == value ? Palette.accent : Palette.line2)
                Text(title).font(.system(size: 13, weight: .medium))
                Text(badge.0).font(.system(size: 10))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(badge.1.opacity(0.18)))
                    .foregroundStyle(badge.1)
            }
            Text(summary).font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(points, id: \.1) { good, text in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: good ? "plus.circle" : "minus.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(good ? Palette.ok : Palette.tertiary)
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
            .stroke(doc.mode == value ? Palette.accent : Palette.line, lineWidth: doc.mode == value ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { doc.mode = value; dirty = true; message = nil }
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

    private var ocproxyBadge: (String, Color) {
        switch ocproxy {
        case .some(true): return ("работает", Palette.ok)
        case .some(false): return ("нужен ocproxy", Palette.warn)
        case .none: return ("проверяю…", Palette.tertiary)
        }
    }

    private func loadVersions() {
        DispatchQueue.global(qos: .utility).async {
            let v = OcbarClient.shared.versions(maxAge: 300)
            DispatchQueue.main.async { ocproxy = v.isEmpty ? nil : v["ocproxy_path"] != nil }
        }
    }

    private func reload() {
        files = ProfileStore.list()
        if selected.isEmpty || !files.contains(selected) {
            selected = files.first ?? ""
        }
        load()
    }

    private func load() {
        guard !selected.isEmpty else { doc = ProfileDoc(); return }
        doc = ProfileStore.load(selected) ?? ProfileDoc(fileName: selected)
        dirty = false
        message = nil
    }

    // Экран меняет три ключа — и только их: файл перечитывается перед
    // записью, чтобы не затереть то, что в него записали после открытия
    // (редактор, разметка, «Запомнить, как я вхожу»).
    private func save() {
        var fresh = ProfileStore.load(selected) ?? doc
        fresh.mode = doc.mode
        fresh.proxyPort = doc.proxyPort
        fresh.systemProxyValue = doc.systemProxyValue
        let errors = ProfileCheck.check(fresh).filter { $0.level == .error }
        guard errors.isEmpty else {
            // Молчать нельзя: кнопка «не срабатывала», и было не понять почему.
            message = "Не сохранено — в профиле ошибки: " + errors.map(\.text).joined(separator: "; ")
                + ". Поправьте их на вкладке «Профили»."
            messageIsError = true
            return
        }
        if let error = ProfileStore.save(fresh) {
            message = "не удалось записать: \(error)"
            messageIsError = true
            return
        }
        doc = fresh
        dirty = false
        message = "сохранено"
        messageIsError = false
    }
}
