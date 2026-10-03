import AppKit
import SwiftUI

struct MainWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Titlebar()
            HStack(spacing: 0) {
                Sidebar()
                content
            }
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
        .ignoresSafeArea()
        .background(WindowChrome(titlebarHeight: 52))
        .preferredColorScheme(.dark)
        .frame(minWidth: 1120, minHeight: 680)
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

    @ViewBuilder private var mainContent: some View {
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

    var body: some View {
        @Bindable var model = model
        HStack {
            HStack(spacing: 20) {
                Color.clear.frame(width: 52, height: 12) // traffic lights
                HStack(spacing: 8) {
                    Icon("audio-waveform", size: 18, color: Theme.accent)
                    Text("Soundflow").font(.ui(14, .semibold)).foregroundStyle(Theme.text)
                }
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

    func makeNSView(context: Context) -> ChromeView {
        let view = ChromeView()
        view.titlebarHeight = titlebarHeight
        return view
    }

    func updateNSView(_ view: ChromeView, context: Context) {
        view.titlebarHeight = titlebarHeight
        view.layoutButtons()
    }

    final class ChromeView: NSView {
        var titlebarHeight: CGFloat = 52
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
            DispatchQueue.main.async { self.layoutButtons() }
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
