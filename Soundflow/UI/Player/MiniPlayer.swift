import AppKit
import SwiftUI

/// Floating mini player: always on top, on every Space, draggable, expanded or collapsed to a capsule.
@MainActor
enum MiniPlayer {
    private static var panel: NSPanel?
    private static var observers: [NSObjectProtocol] = []

    static var isVisible: Bool { panel?.isVisible == true }

    static func toggle(model: AppModel) {
        isVisible ? hide(model: model) : show(model: model)
    }

    static func show(model: AppModel) {
        if panel == nil { panel = makePanel(model: model) }
        guard let panel else { return }
        resize(model: model, animate: false)
        if let origin = model.config.prefs.miniPlayerOrigin, origin.count == 2 {
            panel.setFrameOrigin(NSPoint(x: origin[0], y: origin[1]))
        } else if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 24, y: screen.visibleFrame.minY + 24))
        }
        keepOnScreen(panel)
        panel.orderFrontRegardless()
        model.config.prefs.miniPlayerVisible = true
        model.engine.setMeteringConsumer("mini-player", active: true)
    }

    static func hide(model: AppModel) {
        panel?.orderOut(nil)
        model.config.prefs.miniPlayerVisible = false
        model.engine.setMeteringConsumer("mini-player", active: false)
    }

    /// Fits the panel to its content, keeping the top-left corner in place.
    static func resize(model: AppModel, animate: Bool = true) {
        guard let panel, let content = panel.contentView else { return }
        let size = content.fittingSize
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true, animate: animate)
    }

    private static func makePanel(model: AppModel) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        let host = NSHostingView(rootView: MiniPlayerView().environment(model))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated {
                model.config.prefs.miniPlayerOrigin = [panel.frame.origin.x, panel.frame.origin.y]
            }
        })
        return panel
    }

    private static func keepOnScreen(_ panel: NSPanel) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var origin = panel.frame.origin
        origin.x = min(max(origin.x, visible.minX), visible.maxX - panel.frame.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - panel.frame.height)
        panel.setFrameOrigin(origin)
    }
}

struct MiniPlayerView: View {
    @Environment(AppModel.self) private var model
    @State private var hover = false

    var body: some View {
        let compact = model.config.prefs.miniPlayerCompact
        Group {
            if compact { capsule } else { expanded }
        }
        .padding(18) // room for the shadow
        .onChange(of: compact) { _, _ in
            DispatchQueue.main.async { MiniPlayer.resize(model: model) }
        }
        .onHover { hover = $0 }
        .preferredColorScheme(.dark)
    }

    private var expanded: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                NowPlayingArtwork(size: 64, radius: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.nowPlaying.current?.title ?? "Ничего не играет").font(.ui(15, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(model.nowPlaying.current?.artist.nilIfEmpty ?? model.nowPlaying.current?.bundleID.map(AppInfo.name) ?? "Soundflow")
                        .font(.ui(12)).foregroundStyle(Theme.text2).lineLimit(1)
                    SpectrumView(style: .bars, bandCount: 18, spacing: 2).frame(width: 90, height: 16).padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                TransportControls(size: .medium)
            }
            PlaybackScrubber(height: 3, showsTimes: false)
            HStack {
                if let app = model.nowPlayingApp {
                    let volume = Binding(get: { model.rule(app.bundleID).volume }, set: { model.setVolume(app.bundleID, $0) })
                    Icon("volume-2", size: 13, color: Theme.text3)
                    SFSlider(value: volume, fill: Theme.text.opacity(0.7)).frame(width: 120)
                    Spacer()
                    Menu {
                        Button("По умолчанию") { model.assign(app.bundleID, to: nil) }
                        Divider()
                        ForEach(model.outputOptions.filter(\.connected)) { option in
                            Button(option.name) { model.assign(app.bundleID, to: option.ref) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Icon(model.currentOutputs(app.bundleID).first.map(model.icon(of:)) ?? "speaker", size: 12, color: model.playerPalette.accent)
                            Text(model.outputLabel(app.bundleID)).font(.ui(11)).foregroundStyle(Theme.text2).lineLimit(1)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                    }
                    .menuStyle(.button).buttonStyle(.sfPlain).menuIndicator(.hidden).fixedSize()
                } else {
                    Spacer()
                }
            }
        }
        .padding(12)
        .frame(width: 380)
        .background(chrome(radius: 18))
        .overlay(alignment: .topTrailing) { windowButtons.padding(6) }
    }

    private var capsule: some View {
        HStack(spacing: 10) {
            NowPlayingArtwork(size: 36, radius: 18, glow: false)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.nowPlaying.current?.title ?? "Ничего не играет").font(.ui(12, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(model.nowPlaying.current?.artist.nilIfEmpty ?? "").font(.ui(10)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            SpectrumView(style: .bars, bandCount: 5, spacing: 2).frame(width: 18, height: 14)
            TransportControls(size: .small)
        }
        .padding(.leading, 6).padding(.trailing, 8).padding(.vertical, 6)
        .background(chrome(radius: 26))
        .overlay(alignment: .topTrailing) { windowButtons.offset(x: 8, y: -8) }
    }

    private func chrome(radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color(hex: 0x121318, alpha: 0.92))
            .background(VisualEffectBlur().clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.45), radius: 18, y: 12)
    }

    /// Collapse/expand and close, shown on hover.
    private var windowButtons: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { model.config.prefs.miniPlayerCompact.toggle() }
            } label: {
                Circle().fill(Color.white.opacity(0.1)).frame(width: 18, height: 18)
                    .overlay(Icon(model.config.prefs.miniPlayerCompact ? "chevron-down" : "minus", size: 10, color: Theme.text2))
            }
            .buttonStyle(.sfPlain).help(model.config.prefs.miniPlayerCompact ? "Развернуть" : "Свернуть в капсулу")
            Button { MiniPlayer.hide(model: model) } label: {
                Circle().fill(Color.white.opacity(0.1)).frame(width: 18, height: 18)
                    .overlay(Icon("x", size: 10, color: Theme.text2))
            }
            .buttonStyle(.sfPlain).help("Закрыть мини-плеер")
        }
        .opacity(hover ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

/// Behind-window blur for the floating panel.
struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
