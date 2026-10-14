import SwiftUI

extension AppModel {
    /// The Soundflow app entry for whatever is "Now Playing" (for its volume, output and EQ).
    var nowPlayingApp: AudioApp? {
        guard let bundleID = nowPlaying.current?.bundleID else { return nil }
        return apps.first { $0.bundleID == bundleID }
    }

    /// The accent palette of the current artwork.
    var playerPalette: ArtworkPalette { nowPlaying.palette }
}

/// Artwork with rounded corners and a colored glow; falls back to a gradient tile.
struct NowPlayingArtwork: View {
    @Environment(AppModel.self) private var model
    var size: CGFloat
    var radius: CGFloat
    var glow = true

    var body: some View {
        let palette = model.playerPalette
        ZStack {
            if let image = model.nowPlaying.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .transition(.opacity)
                    .id(model.nowPlaying.current?.artworkID)
            } else {
                LinearGradient(colors: [palette.accent.opacity(0.55), palette.deep], startPoint: .topLeading, endPoint: .bottomTrailing)
                Icon("music", size: size * 0.32, color: .white.opacity(0.85))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .shadow(color: glow ? palette.accent.opacity(0.35) : .clear, radius: size * 0.18, y: size * 0.07)
        .animation(.smooth(duration: 0.5), value: model.nowPlaying.current?.artworkID)
    }
}

/// Previous / play-pause / next.
struct TransportControls: View {
    @Environment(AppModel.self) private var model
    enum Size { case large, medium, small }
    var size: Size = .large

    var body: some View {
        let playing = model.nowPlaying.current?.isPlaying == true
        let palette = model.playerPalette
        let (play, icon, gap): (CGFloat, CGFloat, CGFloat) = switch size {
        case .large: (64, 22, 22)
        case .medium: (38, 16, 14)
        case .small: (34, 15, 18)
        }
        HStack(spacing: gap) {
            Button { model.nowPlaying.previous() } label: {
                Icon("skip-back", size: icon, color: Theme.text).frame(width: play * 0.7, height: play * 0.7).contentShape(Rectangle())
            }
            .buttonStyle(.sfPlain).help("Предыдущий")
            Button { model.nowPlaying.togglePlayPause() } label: {
                Circle().fill(palette.accent)
                    .frame(width: play, height: play)
                    .shadow(color: palette.accent.opacity(size == .large ? 0.45 : 0), radius: 14, y: 8)
                    .overlay(Icon(playing ? "pause" : "play", size: icon + (size == .large ? 4 : 0), color: palette.onAccent)
                        .offset(x: playing ? 0 : icon * 0.08))
            }
            .buttonStyle(.sfPlain).help(playing ? "Пауза" : "Играть")
            .keyboardShortcut(size == .large ? KeyboardShortcut(.space, modifiers: []) : nil)
            Button { model.nowPlaying.next() } label: {
                Icon("skip-forward", size: icon, color: Theme.text).frame(width: play * 0.7, height: play * 0.7).contentShape(Rectangle())
            }
            .buttonStyle(.sfPlain).help("Следующий")
        }
        .disabled(model.nowPlaying.current == nil)
        .animation(.smooth(duration: 0.3), value: palette)
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "—" }
    let total = Int(seconds.rounded(.down))
    return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                         : String(format: "%d:%02d", total / 60, total % 60)
}

/// Progress bar with elapsed/remaining time; drag to seek.
struct PlaybackScrubber: View {
    @Environment(AppModel.self) private var model
    var height: CGFloat = 6
    var showsTimes = true
    var interactive = true
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let current = model.nowPlaying.current
            let duration = current?.duration ?? 0
            let position = current?.position(at: context.date) ?? 0
            let fraction = dragFraction ?? (duration > 0 ? position / duration : 0)
            VStack(spacing: 8) {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.1))
                        Capsule().fill(model.playerPalette.accent).frame(width: max(height, width * fraction))
                        // Thin bars (mini player, menu bar) stay a clean line without a knob.
                        if interactive && duration > 0 && height >= 5 {
                            Circle().fill(.white).frame(width: height + 8, height: height + 8)
                                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                                .offset(x: width * fraction - (height + 8) / 2)
                        }
                    }
                    .frame(height: height)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard interactive, duration > 0 else { return }
                            dragFraction = (value.location.x / max(1, width)).clamped(to: 0...1)
                        }
                        .onEnded { _ in
                            if let dragFraction, duration > 0 { model.nowPlaying.seek(to: dragFraction * duration) }
                            dragFraction = nil
                        })
                }
                .frame(height: height + 8)
                if showsTimes {
                    HStack {
                        Text(formatTime((dragFraction.map { $0 * duration }) ?? position))
                        Spacer()
                        Text(duration > 0 ? "−" + formatTime(max(0, duration - ((dragFraction.map { $0 * duration }) ?? position))) : "")
                            .foregroundStyle(Theme.text3)
                    }
                    .font(.mono(11)).foregroundStyle(Theme.text2)
                }
            }
        }
        .opacity(model.nowPlaying.current?.duration == nil ? 0.4 : 1)
    }
}

/// Keeps one analyzer per view, created lazily on the first frame (and recreated if the band count changes).
final class AnalyzerHolder {
    private var current: SpectrumAnalyzer?

    func analyzer(bands: Int) -> SpectrumAnalyzer {
        if let current, current.bandCount == bands { return current }
        let fresh = SpectrumAnalyzer(bandCount: bands)
        current = fresh
        return fresh
    }
}

/// Live spectrum of the now-playing app's audio, drawn in the artwork color.
struct SpectrumView: View {
    @Environment(AppModel.self) private var model
    var style: VisualizerStyle = .bars
    var bandCount = 40
    var spacing: CGFloat = 4
    @State private var holder = AnalyzerHolder()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { _ in
            let bands = tick()
            let color = model.playerPalette.accent
            Canvas { context, size in
                switch style {
                case .bars: drawBars(&context, size, bands, color)
                case .wave: drawWave(&context, size, bands, color)
                case .ring: drawRing(&context, size, bands, color)
                }
            }
        }
        .accessibilityLabel("Визуализатор звука")
    }

    private func tick() -> [Float] {
        let analyzer = holder.analyzer(bands: bandCount)
        if let source = model.nowPlaying.current?.bundleID, let state = model.engine.renderState(source),
           model.nowPlaying.current?.isPlaying == true {
            analyzer.update(from: state)
        } else {
            analyzer.decay()
        }
        return analyzer.bands
    }

    private func drawBars(_ context: inout GraphicsContext, _ size: CGSize, _ bands: [Float], _ color: Color) {
        let count = CGFloat(bands.count)
        let width = max(1, (size.width - spacing * (count - 1)) / count)
        let gradient = Gradient(colors: [color, color.opacity(0.25)])
        for (index, value) in bands.enumerated() {
            let height = max(2, CGFloat(value) * size.height)
            let rect = CGRect(x: CGFloat(index) * (width + spacing), y: size.height - height, width: width, height: height)
            context.fill(Path(roundedRect: rect, cornerRadius: min(3, width / 2)),
                         with: .linearGradient(gradient, startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: size.height)))
        }
    }

    private func drawWave(_ context: inout GraphicsContext, _ size: CGSize, _ bands: [Float], _ color: Color) {
        guard bands.count > 1 else { return }
        let mid = size.height / 2
        let points = bands.enumerated().map { index, value in
            (x: size.width * CGFloat(index) / CGFloat(bands.count - 1), a: CGFloat(value) * size.height * 0.48)
        }
        func smooth(_ sign: CGFloat) -> Path {
            var path = Path()
            for (index, point) in points.enumerated() {
                let target = CGPoint(x: point.x, y: mid - sign * point.a)
                if index == 0 { path.move(to: target); continue }
                let previous = points[index - 1]
                path.addCurve(to: target, control1: CGPoint(x: (previous.x + point.x) / 2, y: mid - sign * previous.a),
                              control2: CGPoint(x: (previous.x + point.x) / 2, y: target.y))
            }
            return path
        }
        var fill = Path()
        fill.move(to: CGPoint(x: 0, y: mid))
        for point in points { fill.addLine(to: CGPoint(x: point.x, y: mid - point.a)) }
        for point in points.reversed() { fill.addLine(to: CGPoint(x: point.x, y: mid + point.a)) }
        fill.closeSubpath()
        context.fill(fill, with: .color(color.opacity(0.16)))
        context.stroke(smooth(1), with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        context.stroke(smooth(-1), with: .color(color.opacity(0.5)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }

    private func drawRing(_ context: inout GraphicsContext, _ size: CGSize, _ bands: [Float], _ color: Color) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.26
        let maxLength = min(size.width, size.height) * 0.22
        let total = bands.count * 2 // mirrored for symmetry
        for index in 0..<total {
            let value = CGFloat(bands[index < bands.count ? index : total - 1 - index])
            let angle = Double(index) / Double(total) * 2 * .pi - .pi / 2
            let inner = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            let outer = CGPoint(x: center.x + cos(angle) * (radius + 3 + value * maxLength),
                                y: center.y + sin(angle) * (radius + 3 + value * maxLength))
            var path = Path()
            path.move(to: inner)
            path.addLine(to: outer)
            context.stroke(path, with: .color(color.opacity(0.35 + 0.65 * value)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        context.stroke(Path(ellipseIn: CGRect(x: center.x - radius + 6, y: center.y - radius + 6, width: (radius - 6) * 2, height: (radius - 6) * 2)),
                       with: .color(color.opacity(0.25)), lineWidth: 1)
    }
}

/// "Nothing is playing" / "unavailable" placeholder used by every player surface.
struct PlayerEmptyState: View {
    @Environment(AppModel.self) private var model
    var compact = false

    var body: some View {
        let unavailable: String? = if case .unavailable(let reason) = model.nowPlaying.availability { reason } else { nil }
        VStack(spacing: compact ? 6 : 12) {
            Circle().fill(Theme.surface2).frame(width: compact ? 36 : 64, height: compact ? 36 : 64)
                .overlay(Circle().strokeBorder(Theme.border))
                .overlay(Icon(unavailable == nil ? "music" : "circle-alert", size: compact ? 16 : 26, color: Theme.text3))
            Text(unavailable == nil ? "Сейчас ничего не играет" : "Плеер недоступен")
                .font(.ui(compact ? 12 : 15, .semibold)).foregroundStyle(Theme.text)
            Text(unavailable ?? "Включите музыку или видео в любом приложении — плеер подхватит его сам.")
                .font(.ui(compact ? 11 : 12)).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}
