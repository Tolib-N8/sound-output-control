import SwiftUI

/// Design tokens from the Pencil file (`design/app.pen`).
enum Theme {
    static let bg = Color(hex: 0x0D0E11)
    static let surface = Color(hex: 0x15171B)
    static let surface2 = Color(hex: 0x1C1F24)
    static let border = Color(hex: 0x262A31)
    static let track = Color(hex: 0x2C3038)
    static let text = Color(hex: 0xF1F2F4)
    static let text2 = Color(hex: 0x9AA0AB)
    static let text3 = Color(hex: 0x5F6571)
    static let accent = Color(hex: 0xC2F25B)
    static let accentInk = Color(hex: 0x12160A)

    static let menu = Color(hex: 0x1F2228)
    static let menuBorder = Color(hex: 0x343943)
    static let danger = Color(hex: 0xFF6B6B)
    static let dangerFill = Color(hex: 0xE5484D)
    static let success = Color(hex: 0x4ADE80)
    static let warning = Color(hex: 0xFBBF24)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

extension Font {
    /// Inter at the design's weights (400 / 500 / 600).
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name = switch weight {
        case .medium: "Inter-Medium"
        case .semibold, .bold, .heavy, .black: "Inter-SemiBold"
        default: "Inter-Regular"
        }
        return .custom(name, fixedSize: size)
    }

    /// JetBrains Mono for numbers and key caps.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(weight == .regular ? "JetBrainsMono-Regular" : "JetBrainsMono-Medium", fixedSize: size)
    }
}

extension View {
    /// Uppercase section label: 11 pt semibold, tracking 0.8, tertiary color.
    func sectionLabelStyle() -> some View {
        font(.ui(11, .semibold)).tracking(0.8).foregroundStyle(Theme.text3)
    }

    func card(radius: CGFloat = 12, fill: Color = Theme.surface, stroke: Color = Theme.border) -> some View {
        background(RoundedRectangle(cornerRadius: radius).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(stroke, lineWidth: 1))
    }

    func hairline(_ edge: Edge, color: Color = Theme.border) -> some View {
        overlay(alignment: edge.alignment) {
            Rectangle().fill(color)
                .frame(width: edge.isHorizontal ? nil : 1, height: edge.isHorizontal ? 1 : nil)
        }
    }
}

private extension Edge {
    var isHorizontal: Bool { self == .top || self == .bottom }
    var alignment: Alignment {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }
}

struct SectionLabel: View {
    let title: String
    var aside: String?
    var asideView: AnyView?

    init(_ title: String, aside: String? = nil) {
        self.title = title
        self.aside = aside
    }

    var body: some View {
        HStack {
            Text(title).sectionLabelStyle()
            Spacer()
            if let aside { Text(aside).font(.ui(11)).foregroundStyle(Theme.text3) }
        }
    }
}
