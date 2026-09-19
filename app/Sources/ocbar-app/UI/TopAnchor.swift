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

    func attach(_ w: NSWindow) {
        guard w !== window else { return }
        detach()
        window = w
        top = w.frame.maxY
        let nc = NotificationCenter.default
        // queue: nil — обработчик выполняется сразу, в том же потоке: окно
        // не успевает показаться в неверном месте.
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: nil) { [weak self] _ in
            self?.top = w.frame.maxY
        })
        observers.append(nc.addObserver(forName: NSWindow.didResizeNotification, object: w, queue: nil) { [weak self] _ in
            self?.keep()
        })
    }

    func keep() {
        guard let w = window, let top, abs(w.frame.maxY - top) > 0.5 else { return }
        w.setFrameOrigin(NSPoint(x: w.frame.minX, y: top - w.frame.height))
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
