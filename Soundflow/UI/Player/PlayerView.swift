import SwiftUI

/// The "Плеер" mode of the main window: big artwork, transport, live spectrum, and the source
/// app's volume, output and equalizer.
struct PlayerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let palette = model.playerPalette
        Group {
            if model.nowPlaying.current == nil {
                PlayerEmptyState().frame(maxWidth: 420).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 24) {
                    VStack(spacing: 20) {
                        hero
                        visualizerCard
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: 16) {
                        sourceCard
                        equalizerCard
                    }
                    .frame(width: 340)
                }
                .padding(.vertical, 28).padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RadialGradient(colors: [palette.accent.opacity(0.16), .clear], center: UnitPoint(x: 0.25, y: 0.3),
                           startRadius: 0, endRadius: 700)
                .animation(.smooth(duration: 0.8), value: palette)
        )
    }

    // MARK: - Hero

    private var hero: some View {
        let current = model.nowPlaying.current
        return HStack(alignment: .center, spacing: 32) {
            NowPlayingArtwork(size: 300, radius: 22)
            VStack(alignment: .leading, spacing: 14) {
                sourceChip
                Text(current?.title ?? "").font(.ui(40, .semibold)).tracking(-0.8).foregroundStyle(Theme.text)
                    .lineLimit(2).minimumScaleFactor(0.6)
                    .contentTransition(.opacity)
                if let subtitle = current?.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.ui(17)).foregroundStyle(Theme.text2).lineLimit(1)
                }
                PlaybackScrubber().padding(.top, 18)
                HStack(spacing: 18) {
                    TransportControls(size: .large)
                    Spacer().frame(width: 12)
                    Button { MiniPlayer.toggle(model: model) } label: {
                        HStack(spacing: 6) {
                            Icon("picture-in-picture-2", size: 14, color: Theme.text2)
                            Text("Мини-плеер").font(.ui(12, .medium)).foregroundStyle(Theme.text2)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.sfPlain)
                    .help("Плеер поверх всех окон (⌥⌘P)")
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 8)
        .animation(.smooth(duration: 0.4), value: current?.title)
    }

    private var sourceChip: some View {
        let bundleID = model.nowPlaying.current?.bundleID
        return HStack(spacing: 8) {
            if let bundleID { AppIconView(bundleID: bundleID, size: 20) }
            Text("Сейчас играет" + (bundleID.map { " · " + AppInfo.name($0) } ?? ""))
                .font(.ui(12, .medium)).foregroundStyle(Theme.text2)
        }
        .padding(.leading, 6).padding(.trailing, 10).padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
    }

    // MARK: - Visualizer

    private var visualizerCard: some View {
        @Bindable var model = model
        let style = Binding(get: { model.config.prefs.visualizerStyle }, set: { model.config.prefs.visualizerStyle = $0 })
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("СПЕКТР").sectionLabelStyle()
                Spacer()
                SegmentedControl(selection: style, items: VisualizerStyle.allCases.map { .init(value: $0, title: $0.title) },
                                 outerRadius: 8, fill: Theme.bg, itemPadding: EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
            }
            SpectrumView(style: style.wrappedValue, bandCount: style.wrappedValue == .ring ? 48 : 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if model.nowPlaying.current.flatMap({ model.engine.renderState($0.bundleID ?? "") }) == nil,
                       model.engine.permission == .denied {
                        Text("Разрешите «Запись системного звука», чтобы видеть спектр")
                            .font(.ui(11)).foregroundStyle(Theme.text3)
                    }
                }
        }
        .padding(20)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface.opacity(0.8)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.border))
    }

    // MARK: - Source app

    @ViewBuilder private var sourceCard: some View {
        if let app = model.nowPlayingApp {
            let rule = model.rule(app.bundleID)
            let volume = Binding(get: { model.rule(app.bundleID).volume }, set: { model.setVolume(app.bundleID, $0) })
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    AppIconView(bundleID: app.bundleID, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.ui(14, .semibold)).foregroundStyle(Theme.text)
                        Text("Звук этого приложения").font(.ui(11)).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    MuteButton(muted: rule.muted, size: 26) { model.toggleMute(app.bundleID) }
                }
                HStack(spacing: 10) {
                    Icon("volume-2", size: 15, color: Theme.text2)
                    SFSlider(value: volume, fill: model.playerPalette.accent, showsFill: !rule.muted)
                    Text(rule.muted ? "—" : percent(rule.volume)).font(.mono(12)).foregroundStyle(Theme.text)
                        .frame(width: 28, alignment: .trailing)
                }
                OutputPicker(app: app, width: nil)
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface.opacity(0.8)))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.border))
        } else if let bundleID = model.nowPlaying.current?.bundleID {
            HStack(spacing: 12) {
                AppIconView(bundleID: bundleID, size: 36)
                Text("\(AppInfo.name(bundleID)) пока не выводит звук через Core Audio").font(.ui(12)).foregroundStyle(Theme.text2)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface.opacity(0.8)))
        }
    }

    @ViewBuilder private var equalizerCard: some View {
        if let app = model.nowPlayingApp {
            EqualizerView(bundleID: app.bundleID, accent: model.playerPalette.accent)
                .padding(18)
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface.opacity(0.8)))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.border))
        }
    }
}
