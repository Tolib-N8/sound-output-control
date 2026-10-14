import SwiftUI

/// Per-app equalizer: presets, on/off, a live response curve and ten band sliders.
struct EqualizerView: View {
    @Environment(AppModel.self) private var model
    let bundleID: String
    var accent: Color = Theme.accent
    var showsHeader = true

    private var settings: EQSettings { model.rule(bundleID).eq ?? EQSettings() }

    var body: some View {
        let settings = settings
        VStack(alignment: .leading, spacing: 14) {
            if showsHeader {
                HStack {
                    Text("ЭКВАЛАЙЗЕР").sectionLabelStyle()
                    Spacer()
                    SFSwitch(isOn: Binding(get: { settings.enabled }, set: { value in update { $0.enabled = value } }))
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(EQPreset.allCases) { preset in
                        let selected = settings.preset == preset.rawValue
                        Button {
                            update {
                                $0.gains = preset.gains
                                $0.preset = preset.rawValue
                                $0.enabled = true
                            }
                        } label: {
                            Text(preset.title).font(.ui(11, .medium))
                                .foregroundStyle(selected ? Theme.text : Theme.text2)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(selected ? accent.opacity(0.16) : Color.white.opacity(0.04)))
                                .overlay(Capsule().strokeBorder(selected ? accent.opacity(0.5) : Theme.border))
                        }
                        .buttonStyle(.sfPlain)
                    }
                }
            }
            ResponseCurve(settings: settings, accent: accent)
                .frame(height: 70)
                .opacity(settings.enabled ? 1 : 0.4)
            HStack(spacing: 0) {
                ForEach(0..<EQSettings.frequencies.count, id: \.self) { band in
                    BandSlider(value: Binding(
                        get: { settings.gains[band] },
                        set: { gain in
                            update {
                                $0.gains[band] = (gain * 2).rounded() / 2
                                $0.preset = nil // recomputed from the new gains in update()
                                $0.enabled = true
                            }
                        }),
                        label: Self.label(EQSettings.frequencies[band]), accent: accent)
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(minHeight: 150, maxHeight: .infinity)
            .opacity(settings.enabled ? 1 : 0.4)
        }
        .animation(.smooth(duration: 0.25), value: settings)
    }

    private func update(_ change: (inout EQSettings) -> Void) {
        model.updateRule(bundleID) { rule in
            var eq = rule.eq ?? EQSettings()
            change(&eq)
            if eq.preset == nil { eq.preset = EQPreset.allCases.first { $0.gains == eq.gains }?.rawValue }
            rule.eq = eq
        }
    }

    static func label(_ frequency: Double) -> String {
        frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))"
    }
}

/// Combined frequency response of the current settings.
private struct ResponseCurve: View {
    let settings: EQSettings
    let accent: Color

    var body: some View {
        Canvas { context, size in
            let rate = 48000.0
            let filters = Equalizer.filters(for: EQSettings(enabled: true, gains: settings.gains), sampleRate: rate)
            let zero = size.height / 2
            context.fill(Path(CGRect(x: 0, y: zero, width: size.width, height: 1)), with: .color(.white.opacity(0.08)))
            var path = Path()
            var fill = Path()
            fill.move(to: CGPoint(x: 0, y: zero))
            let steps = 120
            for i in 0...steps {
                let fraction = Double(i) / Double(steps)
                let frequency = 20 * pow(20000.0 / 20, fraction)
                let db = Equalizer.responseDB(filters, at: frequency, sampleRate: rate).clamped(to: -15...15)
                let point = CGPoint(x: size.width * fraction, y: zero - CGFloat(db / 15) * (size.height / 2 - 4))
                i == 0 ? path.move(to: point) : path.addLine(to: point)
                fill.addLine(to: point)
            }
            fill.addLine(to: CGPoint(x: size.width, y: zero))
            fill.closeSubpath()
            context.fill(fill, with: .color(accent.opacity(0.14)))
            context.stroke(path, with: .color(accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Vertical ±12 dB slider; double-click resets to 0.
private struct BandSlider: View {
    @Binding var value: Double
    let label: String
    let accent: Color

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let height = proxy.size.height
                let range = EQSettings.range
                let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                let y = height - 7 - (height - 14) * CGFloat(fraction)
                let center = height / 2
                ZStack(alignment: .top) {
                    Capsule().fill(Theme.track).frame(width: 4)
                    Capsule().fill(accent)
                        .frame(width: 4, height: max(2, abs(y - center)))
                        .offset(y: min(y, center))
                    Circle().fill(.white).frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .offset(y: y - 7)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                    let fraction = Double(1 - (gesture.location.y - 7) / max(1, height - 14)).clamped(to: 0...1)
                    value = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
                })
                .onTapGesture(count: 2) { value = 0 }
            }
            Text(label).font(.mono(9)).foregroundStyle(Theme.text3)
        }
        .help("\(label) Гц: \(value > 0 ? "+" : "")\(String(format: "%.1f", value)) дБ")
    }
}
