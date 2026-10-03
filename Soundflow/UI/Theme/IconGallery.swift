#if DEBUG
import SwiftUI

/// Developer gallery (`-SFScreen icons`): every icon with a filmstrip of its press animation.
struct IconGallery: View {
    private let names = LucideGlyphs.paths.keys.sorted()
    private let frames: [Double] = [0, 0.15, 0.3, 0.45, 0.6, 0.8, 1]
    @State private var tick = 0

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 10)], spacing: 10) {
                ForEach(names, id: \.self) { name in
                    let parts = GlyphStore.parts(name)
                    let motion = IconMotions.motion(for: name)
                    VStack(alignment: .leading, spacing: 6) {
                    Text(name).font(.mono(9)).foregroundStyle(Theme.text3)
                    HStack(spacing: 6) {
                        Icon(name, size: 22, color: Theme.accent)
                            .environment(\.iconTrigger, tick)
                            .environment(\.iconInPressable, true)
                            .frame(width: 28)
                        ForEach(frames, id: \.self) { t in
                            GlyphCanvas(parts: parts, color: Theme.text, size: 22, t: t, motion: motion)
                        }
                        Spacer(minLength: 0)
                    }
                    }
                    .padding(8)
                    .card(radius: 8)
                }
            }
            .padding(16)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.6))
                tick += 1
            }
        }
    }
}
#endif
