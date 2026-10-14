import SwiftUI

/// "Now Playing" card at the top of the menu bar popover.
struct NowPlayingCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let palette = model.playerPalette
        if let current = model.nowPlaying.current {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    NowPlayingArtwork(size: 56, radius: 10, glow: false)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(current.title).font(.ui(14, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        Text([current.artist, current.bundleID.map(AppInfo.name)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.ui(11)).foregroundStyle(Theme.text2).lineLimit(1)
                        SpectrumView(style: .bars, bandCount: 14, spacing: 2)
                            .frame(width: 60, height: 12)
                            .padding(.top, 3)
                    }
                    Spacer(minLength: 0)
                    Button { MiniPlayer.toggle(model: model) } label: {
                        RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)).frame(width: 28, height: 28)
                            .overlay(Icon("picture-in-picture-2", size: 14, color: Theme.text2))
                    }
                    .buttonStyle(.sfPlain)
                    .help("Мини-плеер поверх окон")
                }
                PlaybackScrubber(height: 3, showsTimes: false)
                HStack {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(formatTime(current.position(at: context.date))).font(.mono(10)).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    TransportControls(size: .small)
                    Spacer()
                    Text(current.duration.map { "−" + formatTime(max(0, $0 - current.position())) } ?? "")
                        .font(.mono(10)).foregroundStyle(Theme.text3)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [palette.deep, Theme.surface], startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.accent.opacity(0.25)))
            .animation(.smooth(duration: 0.5), value: palette)
        }
    }
}
