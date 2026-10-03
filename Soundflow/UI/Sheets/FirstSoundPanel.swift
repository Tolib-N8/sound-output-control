import AppKit
import SwiftUI

/// Floating panel asking where a newly playing app should send its sound ("Спрашивать при первом звуке").
@MainActor
enum FirstSoundPanel {
    private static var panels: [String: NSPanel] = [:]

    static func show(app: AudioApp, model: AppModel) {
        guard panels[app.bundleID] == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 10),
                            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        let close = { [bundleID = app.bundleID] in
            panels[bundleID]?.close()
            panels[bundleID] = nil
        }
        let view = FirstSoundView(app: app, close: close).environment(model)
        panel.contentView = NSHostingView(rootView: view)
        panel.setContentSize(panel.contentView!.fittingSize)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 16, y: frame.maxY - panel.frame.height - 16 - CGFloat(panels.count) * 12))
        }
        panels[app.bundleID] = panel
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { close() }
    }
}

private struct FirstSoundView: View {
    @Environment(AppModel.self) private var model
    let app: AudioApp
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AppIconView(bundleID: app.bundleID, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                    Text("Начал воспроизводить звук. Куда вывести?").font(.ui(11)).foregroundStyle(Theme.text3)
                }
                Spacer()
                Button(action: close) { Icon("x", size: 14, color: Theme.text3) }.buttonStyle(.sfPlain)
            }
            VStack(spacing: 2) {
                ForEach(model.outputOptions.filter(\.connected)) { option in
                    MenuItem(icon: option.icon, title: option.name, meta: option.isMulti ? option.subtitle : nil,
                             checked: option.ref == model.devices.defaultOutputUID && model.rule(app.bundleID).outputs.isEmpty) {
                        model.assign(app.bundleID, to: option.ref)
                        close()
                    }
                }
            }
            Button("Оставить по умолчанию") {
                model.updateRule(app.bundleID) { _ in }
                close()
            }
            .buttonStyle(.sfGhost)
        }
        .padding(14)
        .frame(width: 320)
        .background(Theme.menu)
        .preferredColorScheme(.dark)
    }
}
