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

        func apply() {
            // Меньше сотни — это ещё не разложенное меню: такому окну размер
            // не меняем, иначе оно схлопнется.
            guard desired > 100, let window, abs(window.frame.height - desired) > 1 else { return }
            let top = window.frame.maxY
            window.setFrame(NSRect(x: window.frame.minX, y: top - desired,
                                   width: window.frame.width, height: desired),
                            display: true)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.desired = height }
}

/// Высота содержимого меню — для MenuWindowFit.
struct MenuHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
