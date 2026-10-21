import AppKit
import SwiftUI

// Меню из SwiftUI-описания (NSHostingMenu) — без экрана: собираем его из
// демо-состояний и читаем получившиеся пункты NSMenu. Открывать меню на
// живом экране для этого не нужно.
extension SelfTest {
    @MainActor static func hostedMenu() -> Int32 {
        var failures: Int32 = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print(ok ? "  [ OK ] \(name)" : "  [FAIL] \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !ok { failures += 1 }
        }
        func build(_ status: Status, busy: String? = nil) -> NSMenu {
            let store = StatusStore(preview: status, busy: busy)
            let menu = NSHostingMenu(rootView: MenuContent().environmentObject(store))
            menu.update()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            return menu
        }
        func titles(_ m: NSMenu) -> [String] { m.items.map { $0.title } }
        let L0 = { (s: String) in L(s) }

        let connected = build(Fixture.status(.connected))
        let t = titles(connected)
        check("меню: «Отключить VPN» первым пунктом", t.first == L0("Отключить VPN"), t.prefix(3).joined(separator: " | "))
        let current = connected.items.first { $0.title.hasPrefix(Fixture.status(.connected).profiles.first?.display ?? "-") }
        check("меню: у поднятого профиля вторая строка", current?.subtitle?.isEmpty == false, current?.subtitle ?? "нет")
        let nets = connected.items.first { $0.title.hasPrefix(L0("Сети в туннеле")) }
        let netItems = nets?.submenu?.items ?? []
        check("меню: сети — подменю с галочками", netItems.count == 3 && netItems.filter { $0.state == .on }.count == 2,
              netItems.map { "\($0.title)=\($0.state == .on)" }.joined(separator: ", "))
        check("меню: «Выйти из ocbar» с ⌘Q", connected.items.contains { $0.title == L0("Выйти из ocbar") && $0.keyEquivalent == "q" })
        let width = connected.size.width
        check("меню: ширина по пунктам, не шире 340", width > 150 && width <= 340, "\(Int(width))")

        let login = build(Fixture.status(.needsLogin))
        check("меню: «Нужен вход» — строки «Войти…» и «Не подключаться»",
              titles(login).contains(L0("Войти…")) && titles(login).contains(L0("Не подключаться")))

        var waiting = Fixture.status(.starting)
        waiting.connectStage = "window"
        let connecting = build(waiting, busy: L0("Подключаюсь…"))
        let step = connecting.items.first { ($0.subtitle ?? "").contains(L0("Ждёт вас в окне входа")) }
        check("меню: шаг подключения второй строкой", step != nil, titles(connecting).prefix(4).joined(separator: " | "))

        let paused = build(Fixture.status(.paused))
        check("меню: на паузе — «Возобновить»", titles(paused).contains(L0("Возобновить")))
        return failures
    }
}
