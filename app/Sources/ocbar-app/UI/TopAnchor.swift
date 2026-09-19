import AppKit
import SwiftUI

// Окно меню из строки состояния держится верхним краем под значком.
// SwiftUI меняет размер окна, когда меняется высота содержимого (второй
// экран «Сети и DNS», предупреждение, пауза), а AppKit при этом оставляет на
// месте нижний левый угол: меню короче — и его верх уезжает вниз от значка.
// Верх запоминаем, когда окно открывается (система ставит его верно), и после
// каждого изменения размера возвращаем окно так, чтобы верх остался там же.
final class TopAnchor: NSObject {
    private(set) weak var window: NSWindow?
    private(set) var top: CGFloat?
    private var observers: [NSObjectProtocol] = []

    private var fixing = false
    /// Подробный журнал перемещений окна меню: временно включён всем, пока
    /// разбираемся, почему меню отъезжает от значка. Строк немного — только
    /// при изменении размера и сдвиге.
    private var trace: Bool { !CommandLine.arguments.contains("--stage") }
    private func log(_ what: String, _ w: NSWindow) {
        guard trace else { return }
        AppLog.write(String(format: "меню-окно: %@ x=%.0f y=%.0f w=%.0f h=%.0f верх=%.0f ждём=%@",
                            what, w.frame.minX, w.frame.minY, w.frame.width, w.frame.height,
                            w.frame.maxY, top.map { String(format: "%.0f", $0) } ?? "—"))
    }

    func attach(_ w: NSWindow) {
        guard w !== window else { return }
        detach()
        window = w
        top = w.isVisible ? w.frame.maxY : nil
        let nc = NotificationCenter.default
        // queue: nil — обработчик выполняется сразу, в том же потоке: окно
        // не успевает показаться в неверном месте.
        log("привязка", w)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didUpdateNotification] {
            observers.append(nc.addObserver(forName: name, object: w, queue: nil) { [weak self] _ in
                // Пока окно только показывается, его ставит система — верх
                // берём оттуда.
                guard let self, !self.fixing else { return }
                if self.top == nil { self.top = w.frame.maxY; self.log("верх запомнен", w) }
            })
        }
        observers.append(nc.addObserver(forName: NSWindow.didResizeNotification, object: w, queue: nil) { [weak self] _ in
            self?.log("размер", w); self?.keep()
        })
        // Окно двигают и после изменения размера — держим верх и тогда.
        observers.append(nc.addObserver(forName: NSWindow.didMoveNotification, object: w, queue: nil) { [weak self] _ in
            self?.log("сдвиг", w); self?.keep()
        })
        // Меню закрылось — следующее открытие система поставит заново.
        observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: nil) { [weak self] _ in
            self?.top = nil; self?.log("закрыто", w)
        })
    }

    func keep() {
        guard !fixing, let w = window, let top, abs(w.frame.maxY - top) > 0.5 else { return }
        fixing = true
        w.setFrameOrigin(NSPoint(x: w.frame.minX, y: top - w.frame.height))
        fixing = false
        log("поправлено", w)
    }

    func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        window = nil
        top = nil
    }

    deinit { detach() }
}

/// Фон для содержимого меню: находит своё окно и привязывает его верх.
struct KeepTopAnchored: NSViewRepresentable {
    final class Probe: NSView {
        let anchor = TopAnchor()
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { anchor.attach(window) }
        }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}
}
