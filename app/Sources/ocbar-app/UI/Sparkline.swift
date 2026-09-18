import SwiftUI

// График трафика за минуту: принято — цветом акцента, отдано — серым.
// Точки копятся справа налево, поэтому свежий график не растягивается на всю
// ширину и видно, что данных пока мало.
struct Sparkline: View {
    let samples: [StatusStore.TrafficSample]
    let capacity: Int
    var active: Bool = true
    var inset: CGFloat = 13

    // Нижний предел шкалы: без него холостые несколько килобайт рисуются
    // горами, и график врёт о нагрузке.
    private let floorRate: Double = 64 * 1024

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let peak = max(floorRate, samples.map { max($0.down, $0.up) }.max() ?? 0)
            let step = w / CGFloat(max(1, capacity - 1))
            let offset = w - step * CGFloat(max(0, samples.count - 1))

            ZStack {
                if samples.count > 1 {
                    line(\.down, peak: peak, h: h, step: step, offset: offset)
                        .fill(Palette.accent.opacity(0.12))
                    line(\.down, peak: peak, h: h, step: step, offset: offset, closed: false)
                        .stroke(Palette.accent, style: .init(lineWidth: 1.5, lineJoin: .round))
                    line(\.up, peak: peak, h: h, step: step, offset: offset, closed: false)
                        .stroke(Palette.tertiary, style: .init(lineWidth: 1, lineJoin: .round))
                } else {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h - 1))
                        p.addLine(to: CGPoint(x: w, y: h - 1))
                    }
                    .stroke(Palette.line2, style: .init(lineWidth: 1, dash: [2, 3]))
                }
            }
            .opacity(active ? 1 : 0.4)
        }
        .frame(height: 42)
        .padding(.horizontal, inset)
        .padding(.top, inset > 0 ? 6 : 0)
        .accessibilityLabel("Трафик за минуту")
    }

    private func line(_ key: KeyPath<StatusStore.TrafficSample, Double>,
                      peak: Double, h: CGFloat, step: CGFloat, offset: CGFloat,
                      closed: Bool = true) -> Path {
        Path { p in
            for (i, s) in samples.enumerated() {
                let x = offset + step * CGFloat(i)
                let y = h - CGFloat(min(1, s[keyPath: key] / peak)) * (h - 2) - 1
                if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
            }
            if closed, let first = samples.first {
                _ = first
                let lastX = offset + step * CGFloat(max(0, samples.count - 1))
                p.addLine(to: CGPoint(x: lastX, y: h))
                p.addLine(to: CGPoint(x: offset, y: h))
                p.closeSubpath()
            }
        }
    }
}
