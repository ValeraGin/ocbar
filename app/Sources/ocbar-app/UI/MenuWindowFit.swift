import AppKit
import SwiftUI

// Окно меню в строке состояния система увеличивает под содержимое, но не
// уменьшает: после возврата с «Сети и DNS» оно оставалось прежней высоты, и
// под значком висела пустота (проверено живым окном — MenuProbe).
// Поэтому высоту содержимого меряем сами и подгоняем под неё окно, оставляя
// верхний край на месте.
struct MenuWindowFit: NSViewRepresentable {
    let height: CGFloat

    final class Probe: NSView {
        var desired: CGFloat = 0 { didSet { apply() } }
        private var observer: NSObjectProtocol?
        private var fixing = false

        func apply() {
            // Меньше сотни — это ещё не разложенное меню: такому окну размер
            // не меняем, иначе оно схлопнется.
            guard !fixing, desired > 100, let window else { return }
            fixing = true
            defer { fixing = false }
            // Предел размера — та же высота: попытка системы поставить окно
            // выше (она берёт с запасом) не пройдёт, и промежуточного кадра
            // не видно.
            let size = NSSize(width: window.frame.width, height: desired)
            if window.contentMinSize != size || window.contentMaxSize != size {
                window.contentMinSize = size
                window.contentMaxSize = size
                window.minSize = size
                window.maxSize = size
            }
            guard abs(window.frame.height - desired) > 1 else { return }
            let top = window.frame.maxY
            window.setFrame(NSRect(x: window.frame.minX, y: top - desired,
                                   width: window.frame.width, height: desired),
                            display: true, animate: false)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
            if let window {
                // Система, увеличив окно под содержимое, берёт высоту с запасом.
                // Поправляем сразу в том же событии, иначе виден скачок.
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification, object: window, queue: nil) { [weak self] _ in
                    self?.apply()
                }
            }
            apply()
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.desired = height }
}

extension MenuWindowFit {
    /// Не показывать промежуточные кадры до конца перерисовки: при смене
    /// экрана SwiftUI успевает разложить содержимое «с запасом» (на 22 точки
    /// выше) и окно на миг дёргается.
    static func freezeUntilFlush() {
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && abs($0.frame.width - MenuView.width) < 2
        }) else { return }
        window.disableScreenUpdatesUntilFlush()
    }
}

/// Высота содержимого меню — для MenuWindowFit.
struct MenuHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
