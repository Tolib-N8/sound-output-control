import SwiftUI

/// Re-renders its content ~20 times a second with the latest engine level.
struct LiveLevel<Content: View>: View {
    let level: () -> Float
    @ViewBuilder let content: (Float) -> Content

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20)) { _ in
            content(level())
        }
    }
}

/// Converts a linear RMS level to a 0…1 display value (‑50 dBFS … ‑3 dBFS, the loud end of music).
func meterFraction(_ level: Float) -> Double {
    guard level > 0.0001 else { return 0 }
    let db = 20 * log10(Double(level))
    return ((db + 50) / 47).clamped(to: 0...1)
}

/// Five tiny bars next to an app's status (playing indicator).
struct MiniBars: View {
    let level: Double
    var color: Color = Theme.accent
    private let shape: [Double] = [0.5, 0.9, 0.6, 1, 0.4]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                let wobble = 0.55 + 0.45 * sin(Double(index) * 1.7 + level * 9)
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 2, height: max(2, 10 * shape[index] * max(0.25, level) * wobble))
            }
        }
        .frame(width: 18, height: 10, alignment: .bottom)
        .animation(.linear(duration: 0.05), value: level)
    }
}

/// Ten bars of increasing height (device load columns).
struct StairBars: View {
    let level: Double
    var count = 10

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<count, id: \.self) { index in
                let lit = Double(index) < level * Double(count)
                RoundedRectangle(cornerRadius: 1)
                    .fill(lit ? Theme.accent : Theme.track)
                    .frame(width: 3, height: CGFloat(4 + index))
            }
        }
    }
}

/// Segmented stereo channel meter (26 segments).
struct SegmentMeter: View {
    let label: String
    let level: Double
    var segments = 26

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.mono(10)).foregroundStyle(Theme.text3).frame(width: 6)
            GeometryReader { proxy in
                let width = (proxy.size.width - CGFloat(segments - 1) * 2) / CGFloat(segments)
                HStack(spacing: 2) {
                    ForEach(0..<segments, id: \.self) { index in
                        let position = Double(index) / Double(segments)
                        let lit = position < level
                        RoundedRectangle(cornerRadius: 1)
                            .fill(lit ? (position > 0.88 ? Theme.danger : position > 0.72 ? Theme.warning : Theme.accent) : Theme.track)
                            .frame(width: width, height: 6)
                    }
                }
            }
            .frame(height: 6)
        }
    }
}
