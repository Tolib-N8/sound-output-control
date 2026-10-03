import SwiftUI

/// The logo + name lockup. Rendered large in the launch overlay and at 1× in the titlebar.
struct BrandView: View {
    var scale: CGFloat = 1
    var showsName = true

    var body: some View {
        HStack(spacing: 8 * scale) {
            Icon("audio-waveform", size: 18 * scale, color: Theme.accent)
            if showsName {
                Text("Soundflow").font(.ui(14 * scale, .semibold)).foregroundStyle(Theme.text)
                    .fixedSize()
                    .transition(.asymmetric(
                        insertion: AnyTransition.modifier(active: NameReveal(progress: 0, distance: 10 * scale),
                                                          identity: NameReveal(progress: 1, distance: 10 * scale)),
                        removal: .opacity))
            }
        }
    }
}

/// The name slides out from behind the logo while fading in and coming into focus.
private struct NameReveal: ViewModifier {
    let progress: Double
    let distance: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 6)
            .offset(x: -(1 - progress) * distance)
    }
}

/// Frame of the titlebar brand in the window's coordinate space.
struct BrandFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

enum LaunchStage: Equatable {
    /// Overlay covers the window; the logo and name animate in the center.
    case intro
    /// The brand flies to the titlebar while the interface fades in.
    case settling
    case done
}

/// Launch animation: the animated logo appears, slides left as the name appears, then both land in the titlebar.
struct LaunchOverlay: View {
    @Binding var stage: LaunchStage
    /// Where the brand ends up (the titlebar brand), in the window coordinate space.
    let target: CGRect

    private static let scale: CGFloat = 2.6
    @State private var logoVisible = false
    @State private var showsName = false
    @State private var logoTrigger = 0

    var body: some View {
        GeometryReader { proxy in
            let settled = stage != .intro
            let center = settled && target != .zero
                ? CGPoint(x: target.midX, y: target.midY)
                : CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2 - 12)
            ZStack {
                Theme.bg.opacity(settled ? 0 : 1)
                BrandView(scale: Self.scale, showsName: showsName)
                    .environment(\.iconTrigger, logoTrigger)
                    .environment(\.iconInPressable, true)
                    .scaleEffect((settled ? 1 / Self.scale : 1) * (logoVisible ? 1 : 0.8))
                    .opacity(logoVisible ? 1 : 0)
                    .position(center)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: skip)
        .task { await run() }
    }

    private func run() async {
        // Let the window finish appearing so the first beat isn't missed.
        guard await pause(0.2) else { return }
        withAnimation(.easeOut(duration: 0.35)) { logoVisible = true }
        logoTrigger += 1
        guard await pause(0.75) else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { showsName = true }
        guard await pause(0.55) else { return }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.84)) { stage = .settling }
        guard await pause(0.6) else { return }
        stage = .done
    }

    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled && stage != .done
    }

    private func skip() {
        guard stage == .intro else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            showsName = true
            logoVisible = true
            stage = .settling
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.45))
            stage = .done
        }
    }
}
