import AppKit
import SwiftUI

struct MainWindowView: View {
    @Environment(AppModel.self) private var model

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var launchStage: LaunchStage = .intro
    @State private var brandFrame: CGRect = .zero

    var body: some View {
        let revealed = launchStage != .intro
        VStack(spacing: 0) {
            Titlebar(brandVisible: launchStage == .done)
            HStack(spacing: 0) {
                Sidebar()
                content
            }
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed ? 0 : 6)
        }
        .background(Theme.bg)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                DisconnectToast(toast: toast)
                    .padding(.bottom, 24)
                    .padding(.leading, 272)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: model.toast)
        .overlay {
            if launchStage != .done {
                LaunchOverlay(stage: $launchStage, target: brandFrame)
            }
        }
        .onPreferenceChange(BrandFrameKey.self) { brandFrame = $0 }
        .coordinateSpace(name: "window")
        .ignoresSafeArea()
        .background(WindowChrome(titlebarHeight: 52) { visible in model.engine.meteringEnabled = visible })
        .preferredColorScheme(.dark)
        .frame(minWidth: 1120, minHeight: 680)
        .onAppear {
            // Plays once per app launch, not every time the window is reopened.
            if model.launchAnimationPlayed || reduceMotion { launchStage = .done }
            model.launchAnimationPlayed = true
        }
    }

    @ViewBuilder private var content: some View {
        #if DEBUG
        if model.debugScreen == "menubar" {
            MenuBarPopover().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.debugScreen == "icons" {
            IconGallery()
        } else {
            mainContent
        }
        #else
        mainContent
        #endif
    }

    /// Identity and depth of the current scene, used for the transition between scenes.
    private var scene: (id: String, rank: Int) {
        switch model.selection {
        case .device(let uid): ("device:\(uid)", 2)
        case .multiOutput(let id): ("multi:\(id)", 2)
        default: model.mode == .list ? ("list", 0) : ("map", 1)
        }
    }

    private var mainContent: some View {
        let scene = scene
        return SceneContainer(id: scene.id, rank: scene.rank) { sceneContent }
    }

    @ViewBuilder private var sceneContent: some View {
        switch model.selection {
        case .device(let uid):
            DeviceDetailView(uid: uid)
        case .multiOutput(let id):
            MultiOutputDetailView(id: id)
        default:
            switch model.mode {
            case .list:
                HStack(spacing: 0) {
                    AppListView()
                    if case .app(let bundleID) = model.selection, let app = model.processes.app(bundleID) {
                        AppInspector(app: app)
                            .frame(width: 340)
                            .transition(.move(edge: .trailing))
                    }
                }
            case .map:
                OutputMapView()
            }
        }
    }
}

// MARK: - Titlebar

struct Titlebar: View {
    @Environment(AppModel.self) private var model
    var brandVisible = true

    var body: some View {
        @Bindable var model = model
        HStack {
            HStack(spacing: 20) {
                Color.clear.frame(width: 52, height: 12) // traffic lights
                BrandView()
                    .opacity(brandVisible ? 1 : 0)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: BrandFrameKey.self, value: proxy.frame(in: .named("window")))
                    })
                SegmentedControl(selection: $model.mode, items: [
                    .init(value: .list, title: "Список", icon: "list"),
                    .init(value: .map, title: "Карта", icon: "workflow"),
                ], outerRadius: 8, fill: Theme.bg, itemPadding: EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
                .onChange(of: model.mode) { _, _ in
                    if case .device = model.selection { model.selection = nil }
                    if case .multiOutput = model.selection { model.selection = nil }
                }
            }
            Spacer()
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    Icon("search", size: 14, color: Theme.text3)
                    TextField("", text: $model.search, prompt: Text("Найти приложение").foregroundStyle(Theme.text3))
                        .textFieldStyle(.plain)
                        .font(.ui(12))
                        .foregroundStyle(Theme.text)
                }
                .padding(.horizontal, 10)
                .frame(width: 220, height: 30)
                .card(radius: 8, fill: Theme.surface2)

                Divider1(vertical: true).frame(height: 20)

                MasterVolume()
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(Theme.surface)
        .hairline(.bottom)
    }
}

struct MasterVolume: View {
    @Environment(AppModel.self) private var model
    var sliderWidth: CGFloat = 120

    var body: some View {
        let volume = Binding(get: { Double(model.mainVolume) }, set: { model.mainVolume = Float($0) })
        HStack(spacing: 10) {
            Button { model.muteAll() } label: {
                Icon(model.mainMuted ? "volume-x" : "volume-2", size: 16, color: model.mainMuted ? Theme.danger : Theme.text2)
            }
            .buttonStyle(.sfPlain)
            .help(model.mainMuted ? "Включить звук" : "Выключить звук")
            SFSlider(value: volume, fill: Theme.text)
                .frame(width: sliderWidth)
                .opacity(model.mainMuted ? 0.5 : 1)
            Text(percent(volume.wrappedValue)).font(.mono(12)).foregroundStyle(Theme.text2).frame(width: 24, alignment: .trailing)
        }
        .disabled(model.devices.defaultDevice?.volume == nil)
    }
}

// MARK: - Window chrome

/// Configures the hosting NSWindow: transparent titlebar, and traffic lights centered in our custom bar.
struct WindowChrome: NSViewRepresentable {
    var titlebarHeight: CGFloat
    /// Reports whether the window is actually on screen (not closed, minimized or fully covered).
    var onVisibilityChange: ((Bool) -> Void)?

    func makeNSView(context: Context) -> ChromeView {
        let view = ChromeView()
        view.titlebarHeight = titlebarHeight
        view.onVisibilityChange = onVisibilityChange
        return view
    }

    func updateNSView(_ view: ChromeView, context: Context) {
        view.titlebarHeight = titlebarHeight
        view.onVisibilityChange = onVisibilityChange
        view.layoutButtons()
    }

    final class ChromeView: NSView {
        var titlebarHeight: CGFloat = 52
        var onVisibilityChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(Theme.bg)
            for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.layoutButtons() }
                })
            }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                let closing = name == NSWindow.willCloseNotification
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reportVisibility(closing: closing) }
                })
            }
            DispatchQueue.main.async {
                self.layoutButtons()
                self.reportVisibility(closing: false)
            }
        }

        private func reportVisibility(closing: Bool) {
            guard let window else { return }
            onVisibilityChange?(!closing && window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
        }

        func layoutButtons() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            // Grow the titlebar container so buttons placed lower are not clipped.
            if let titlebar = window.standardWindowButton(.closeButton)?.superview?.superview {
                var frame = titlebar.frame
                frame.size.height = titlebarHeight
                frame.origin.y = window.frame.height - titlebarHeight
                titlebar.frame = frame
            }
            for (index, type) in buttons.enumerated() {
                guard let button = window.standardWindowButton(type), let container = button.superview else { continue }
                let y = container.frame.height - titlebarHeight / 2 - button.frame.height / 2
                button.setFrameOrigin(NSPoint(x: 20 + CGFloat(index) * 20, y: y))
            }
        }
    }
}
