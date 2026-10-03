import SwiftUI

// MARK: - Sliders

/// Thin slider from the design: 4 pt track, 14 pt knob, colored fill.
struct SFSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var fill: Color = Theme.accent
    var knob: Color = .white
    var showsFill = true
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var dragging = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound)).clamped(to: 0...1)
            let x = 7 + (width - 14) * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track).frame(height: 4)
                if showsFill {
                    Capsule().fill(fill).frame(width: max(0, x), height: 4)
                }
                Circle()
                    .fill(knob)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .scaleEffect(dragging ? 1.12 : 1)
                    .offset(x: x - 7)
            }
            .frame(height: 16)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !dragging { dragging = true; onEditingChanged(true) }
                        let fraction = ((gesture.location.x - 7) / max(1, width - 14)).clamped(to: 0...1)
                        value = range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditingChanged(false)
                    }
            )
            .animation(.easeOut(duration: 0.12), value: dragging)
        }
        .frame(height: 16)
    }
}

/// Balance slider: the fill grows from the center towards L or R.
struct BalanceSlider: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let center = width / 2
            let x = 7 + (width - 14) * CGFloat((value + 1) / 2)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track).frame(height: 4)
                Rectangle().fill(Theme.text3).frame(width: 1, height: 8).offset(x: center - 0.5)
                Capsule().fill(Theme.accent)
                    .frame(width: abs(x - center), height: 4)
                    .offset(x: min(x, center))
                Circle().fill(.white).frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: x - 7)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                var fraction = Double(((gesture.location.x - 7) / max(1, width - 14)).clamped(to: 0...1)) * 2 - 1
                if abs(fraction) < 0.04 { fraction = 0 } // snap to center
                value = fraction
            })
            .onTapGesture(count: 2) { value = 0 }
        }
        .frame(height: 16)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

// MARK: - Toggle

struct SFToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 0)
            SFSwitch(isOn: configuration.$isOn)
        }
    }
}

struct SFSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? Theme.accent : Theme.track)
            Circle().fill(isOn ? Theme.accentInk : .white).frame(width: 14, height: 14).padding(2)
        }
        .frame(width: 32, height: 18)
        .contentShape(Capsule())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() } }
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "Вкл" : "Выкл")
    }
}

/// Title + subtitle + switch, the most common settings row.
struct ToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.ui(12, .medium)).foregroundStyle(Theme.text)
                if let subtitle { Text(subtitle).font(.ui(11)).foregroundStyle(Theme.text3) }
            }
            Spacer(minLength: 0)
            SFSwitch(isOn: $isOn)
        }
    }
}

// MARK: - Segmented

struct SegmentedControl<Value: Hashable>: View {
    struct Item {
        let value: Value
        let title: String
        var icon: String?
    }

    @Binding var selection: Value
    let items: [Item]
    var outerRadius: CGFloat = 9
    var fill: Color = Theme.surface
    var itemPadding = EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                let selected = item.value == selection
                Button {
                    selection = item.value
                } label: {
                    HStack(spacing: 6) {
                        if let icon = item.icon { Icon(icon, size: 13, color: selected ? Theme.accent : Theme.text3) }
                        Text(item.title).font(.ui(12, .medium)).foregroundStyle(selected ? Theme.text : Theme.text2)
                    }
                    .padding(itemPadding)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: outerRadius - 2).fill(Theme.surface2)
                                .overlay(RoundedRectangle(cornerRadius: outerRadius - 2).strokeBorder(Theme.border))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .card(radius: outerRadius, fill: fill)
    }
}

// MARK: - Buttons

struct SFButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger, ghost }
    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(12, .medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(background))
            .overlay {
                if kind == .secondary || kind == .danger {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(kind == .danger ? Theme.dangerFill.opacity(0.4) : Theme.border)
                }
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .primary: Theme.accentInk
        case .secondary: Theme.text
        case .danger: Theme.danger
        case .ghost: Theme.text2
        }
    }

    private var background: Color {
        switch kind {
        case .primary: Theme.accent
        case .secondary: Theme.surface2
        case .danger: Theme.dangerFill.opacity(0.13)
        case .ghost: .clear
        }
    }
}

extension ButtonStyle where Self == SFButtonStyle {
    static var sfPrimary: SFButtonStyle { SFButtonStyle(kind: .primary) }
    static var sfSecondary: SFButtonStyle { SFButtonStyle(kind: .secondary) }
    static var sfDanger: SFButtonStyle { SFButtonStyle(kind: .danger) }
    static var sfGhost: SFButtonStyle { SFButtonStyle(kind: .ghost) }
}

/// Button with an icon and title, as used across the design ("+ Создать", "Сделать основным").
struct IconLabel: View {
    let icon: String
    let title: String
    var color: Color?

    var body: some View {
        HStack(spacing: 8) {
            Icon(icon, size: 14, color: color ?? .primary)
            Text(title)
        }
    }
}

// MARK: - Small pieces

struct KeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.mono(11))
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(minWidth: 21)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.surface2))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border))
    }
}

struct KeyCaps: View {
    let caps: [String]
    var body: some View {
        HStack(spacing: 4) { ForEach(Array(caps.enumerated()), id: \.offset) { KeyCap(label: $0.element) } }
    }
}

struct Checkbox: View {
    let checked: Bool

    var body: some View {
        ZStack {
            if checked {
                RoundedRectangle(cornerRadius: 4).fill(Theme.accent)
                Icon("check", size: 12, color: Theme.accentInk)
            } else {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.text3, lineWidth: 1.5)
            }
        }
        .frame(width: 16, height: 16)
    }
}

struct RadioDot: View {
    let selected: Bool
    var body: some View {
        ZStack {
            Circle().strokeBorder(selected ? Theme.accent : Theme.text3, lineWidth: 1.5)
            if selected { Circle().fill(Theme.accent).frame(width: 8, height: 8) }
        }
        .frame(width: 16, height: 16)
    }
}

struct Badge: View {
    let text: String
    var color: Color = Theme.text2
    var fill: Color = .clear
    var stroke: Color = Theme.border

    var body: some View {
        Text(text)
            .font(.ui(9, .semibold)).tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(stroke))
    }
}

/// Status pill like "● Подключено" / "● Активен".
struct StatusPill: View {
    let text: String
    var color: Color = Theme.success

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.ui(11, .medium)).foregroundStyle(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// Real app icon with the design's rounded corners.
struct AppIconView: View {
    let bundleID: String
    var size: CGFloat = 36
    var dimmed = false

    var body: some View {
        Image(nsImage: AppInfo.icon(bundleID))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .opacity(dimmed ? 0.5 : 1)
    }
}

/// Square icon box (32×32, radius 8) used for devices.
struct IconBox: View {
    let icon: String
    var size: CGFloat = 32
    var iconSize: CGFloat = 16
    var active = false
    var fill: Color?

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4)
            .fill(fill ?? (active ? Theme.accent : Theme.surface2))
            .frame(width: size, height: size)
            .overlay(Icon(icon, size: iconSize, color: active ? Theme.accentInk : Theme.text2))
    }
}

struct Divider1: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Theme.border).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}
