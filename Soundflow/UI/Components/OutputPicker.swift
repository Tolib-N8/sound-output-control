import SwiftUI

/// The row's "Output Select" button that opens the output menu.
struct OutputPicker: View {
    @Environment(AppModel.self) private var model
    let app: AudioApp
    var width: CGFloat? = 188
    @State private var open = false

    var body: some View {
        let rule = model.rule(app.bundleID)
        let status = model.status(app.bundleID)
        let explicit = !rule.outputs.isEmpty
        let fallback = status?.route.isFallback == true || status?.route.isWaiting == true
        let iconName = rule.outputs.count > 1 ? "git-merge" : rule.outputs.first.map(model.icon(of:))
            ?? model.devices.defaultDevice?.kind.icon ?? "speaker"

        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                Icon(fallback ? model.devices.device(uid: status?.route.outputs.first)?.kind.icon ?? iconName : iconName,
                     size: 14, color: fallback ? Theme.warning : explicit ? Theme.accent : Theme.text2)
                Text(model.outputLabel(app.bundleID) + (status?.route.isWaiting == true ? " · пауза" : fallback ? " · резерв" : ""))
                    .font(.ui(12)).foregroundStyle(explicit || fallback ? Theme.text : Theme.text2).lineLimit(1)
                Spacer(minLength: 0)
                Icon("chevrons-up-down", size: 12, color: Theme.text3)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface2))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(fallback ? Theme.warning.opacity(0.33) : open ? Theme.accent.opacity(0.53) : explicit ? Theme.accent.opacity(0.33) : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            OutputMenu(app: app) { open = false }
        }
    }
}

struct OutputMenu: View {
    @Environment(AppModel.self) private var model
    let app: AudioApp
    let dismiss: () -> Void

    var body: some View {
        let rule = model.rule(app.bundleID)
        VStack(alignment: .leading, spacing: 2) {
            Text("ВЫВОД ДЛЯ \(app.name.uppercased())")
                .font(.ui(10, .semibold)).tracking(0.8).foregroundStyle(Theme.text3)
                .padding(EdgeInsets(top: 6, leading: 8, bottom: 4, trailing: 8))

            MenuItem(icon: model.devices.defaultDevice?.kind.icon ?? "speaker", title: "По умолчанию",
                     meta: model.devices.defaultDevice?.name, checked: rule.outputs.isEmpty) {
                model.assign(app.bundleID, to: nil)
                dismiss()
            }
            ForEach(model.outputOptions) { option in
                MenuItem(icon: option.icon, title: option.name,
                         meta: option.isMulti ? option.subtitle : batteryMeta(option),
                         checked: rule.outputs.contains(option.ref), disabled: !option.connected) {
                    let additive = NSEvent.modifierFlags.contains(.option)
                    model.assign(app.bundleID, to: option.ref, additive: additive)
                    if !additive { dismiss() }
                }
            }
            Rectangle().fill(Theme.menuBorder).frame(height: 1).padding(.vertical, 2)
            MenuItem(icon: "layers", title: "Вывести на несколько…", secondary: true) {
                model.selection = .app(app.bundleID)
                dismiss()
            }
            MenuItem(icon: "settings-2", title: "Звук в настройках macOS", secondary: true) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                dismiss()
            }
        }
        .padding(6)
        .frame(width: 248)
        .background(Theme.menu)
    }

    private func batteryMeta(_ option: OutputOption) -> String? {
        guard option.connected, let device = model.devices.device(uid: option.ref), device.transport == .bluetooth,
              let level = model.battery.level(for: device.name) else { return nil }
        return "\(level)%"
    }
}

struct MenuItem: View {
    let icon: String
    let title: String
    var meta: String?
    var checked = false
    var disabled = false
    var secondary = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Icon(icon, size: 14, color: checked ? Theme.accent : Theme.text2)
                Text(title).font(.ui(12)).foregroundStyle(secondary ? Theme.text2 : Theme.text).lineLimit(1)
                Spacer(minLength: 0)
                if let meta { Text(meta).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1) }
                if checked { Icon("check", size: 14, color: Theme.accent) }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6).fill(checked ? Theme.accent.opacity(0.1) : hover ? Color.white.opacity(0.05) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onHover { hover = $0 }
    }
}
