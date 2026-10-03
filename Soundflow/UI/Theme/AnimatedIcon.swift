import SwiftUI

// MARK: - Press plumbing

private struct IconTriggerKey: EnvironmentKey { static let defaultValue = 0 }
private struct IconPressedKey: EnvironmentKey { static let defaultValue = false }
private struct IconInPressableKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Incremented when the enclosing control is activated; icons play their animation on change.
    var iconTrigger: Int {
        get { self[IconTriggerKey.self] }
        set { self[IconTriggerKey.self] = newValue }
    }

    /// True while the enclosing control is held down; icons squash slightly.
    var iconPressed: Bool {
        get { self[IconPressedKey.self] }
        set { self[IconPressedKey.self] = newValue }
    }

    /// Set by controls that drive `iconTrigger`, so icons inside them don't add their own tap handling.
    var iconInPressable: Bool {
        get { self[IconInPressableKey.self] }
        set { self[IconInPressableKey.self] = newValue }
    }
}

/// Publishes a button's press state to the icons in its label.
struct IconPressReporter<Content: View>: View {
    let isPressed: Bool
    @ViewBuilder var content: Content
    @State private var count = 0

    var body: some View {
        content
            .environment(\.iconPressed, isPressed)
            .environment(\.iconTrigger, count)
            .environment(\.iconInPressable, true)
            .onChange(of: isPressed) { _, pressed in
                if !pressed { count += 1 }
            }
    }
}

/// `.plain` replacement that animates icons on press.
struct SFPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconPressReporter(isPressed: configuration.isPressed) {
            configuration.label.contentShape(Rectangle())
        }
    }
}

extension ButtonStyle where Self == SFPlainButtonStyle {
    static var sfPlain: SFPlainButtonStyle { SFPlainButtonStyle() }
}

/// Tap handler for rows and cards: runs `action` and plays the animation of the icons inside.
///
/// It must be the view's own tap gesture — a separate inner tap gesture would win over an outer
/// `onTapGesture` and swallow the click.
private struct IconTap: ViewModifier {
    let count: Int
    let animate: Bool
    let action: () -> Void
    @State private var trigger = 0

    func body(content: Content) -> some View {
        content
            .environment(\.iconTrigger, trigger)
            .environment(\.iconInPressable, true)
            .onTapGesture(count: count) {
                if animate { trigger += 1 }
                action()
            }
    }
}

extension View {
    func iconTap(count: Int = 1, animate: Bool = true, perform action: @escaping () -> Void) -> some View {
        modifier(IconTap(count: count, animate: animate, action: action))
    }
}

// MARK: - Icon

/// Lucide icon drawn part by part so every icon can play its own animation when pressed.
struct Icon: View {
    let name: String
    var size: CGFloat = 14
    var color: Color = Theme.text2

    @Environment(\.iconTrigger) private var trigger
    @Environment(\.iconPressed) private var pressed
    @Environment(\.iconInPressable) private var inPressable
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ownTrigger = 0

    init(_ name: String, size: CGFloat = 14, color: Color = Theme.text2) {
        self.name = name
        self.size = size
        self.color = color
    }

    var body: some View {
        let parts = GlyphStore.parts(name)
        let motion = IconMotions.motion(for: name)
        KeyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? 0 : trigger &+ ownTrigger) { t in
            GlyphCanvas(parts: parts, color: color, size: size, t: t, motion: motion)
        } keyframes: { _ in
            KeyframeTrack {
                MoveKeyframe(0.0)
                LinearKeyframe(1.0, duration: motion.duration)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(pressed && !reduceMotion ? 0.84 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.55), value: pressed)
        .modifier(StandaloneTap(enabled: !inPressable) { ownTrigger += 1 })
        .accessibilityHidden(true)
    }
}

/// Decorative icons outside any control still react to a click.
private struct StandaloneTap: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.contentShape(Rectangle()).onTapGesture(perform: action)
        } else {
            content
        }
    }
}

@MainActor
enum GlyphStore {
    private static var cache: [String: [Path]] = [:]

    static func parts(_ name: String) -> [Path] {
        if let cached = cache[name] { return cached }
        let parts = (LucideGlyphs.paths[name] ?? LucideGlyphs.paths["circle"] ?? []).map(SVGPath.parse)
        cache[name] = parts
        return parts
    }
}

/// Draws the parts in a 24×24 space, applying each part's pose for animation time `t` (0…1, rest at 1).
struct GlyphCanvas: View {
    let parts: [Path]
    let color: Color
    let size: CGFloat
    let t: Double
    let motion: IconMotion

    var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 24
            let toCanvas = CGAffineTransform(scaleX: scale, y: scale)
            let style = StrokeStyle(lineWidth: 2 * scale, lineCap: .round, lineJoin: .round)
            let whole = motion.whole?(t) ?? PartPose()
            for (index, part) in parts.enumerated() {
                let pose = motion.part?(index, t) ?? PartPose()
                let opacity = pose.opacity * whole.opacity
                guard opacity > 0.01 else { continue }
                var path = part
                let trim = pose.trim
                if trim.lowerBound > 0 || trim.upperBound < 1 {
                    guard trim.upperBound > trim.lowerBound else { continue }
                    path = path.trimmedPath(from: trim.lowerBound, to: trim.upperBound)
                }
                path = path.applying(pose.transform.concatenating(whole.transform).concatenating(toCanvas))
                var layer = context
                layer.opacity = opacity
                layer.stroke(path, with: .color(color), style: style)
            }
        }
        .frame(width: size, height: size)
    }
}
