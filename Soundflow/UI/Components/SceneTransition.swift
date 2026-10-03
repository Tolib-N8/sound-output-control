import SwiftUI

/// Hosts one "scene" at a time and cross-fades between them with a light directional shift.
///
/// `rank` orders scenes (e.g. list < map < device): moving to a higher rank slides the new
/// scene in from the right, going back slides it in from the left.
struct SceneContainer<Content: View>: View {
    let id: AnyHashable
    let rank: Int
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastRank: Int?

    var body: some View {
        // Computed before `lastRank` updates, so the transition sees the direction of this change.
        let direction: CGFloat = rank >= (lastRank ?? rank) ? 1 : -1
        ZStack {
            content
                .id(id)
                .transition(reduceMotion ? .opacity : .scene(direction))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.32), value: id)
        .onAppear { lastRank = rank }
        .onChange(of: rank) { _, new in lastRank = new }
    }
}

private struct SceneShift: ViewModifier {
    let opacity: Double
    let x: CGFloat
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .scaleEffect(scale)
            .offset(x: x)
    }
}

extension AnyTransition {
    /// Incoming scene fades in from a short distance; the outgoing one drifts the other way and fades.
    static func scene(_ direction: CGFloat) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: SceneShift(opacity: 0, x: 18 * direction, scale: 0.985),
                                 identity: SceneShift(opacity: 1, x: 0, scale: 1)),
            removal: .modifier(active: SceneShift(opacity: 0, x: -10 * direction, scale: 0.995),
                               identity: SceneShift(opacity: 1, x: 0, scale: 1))
        )
    }
}
