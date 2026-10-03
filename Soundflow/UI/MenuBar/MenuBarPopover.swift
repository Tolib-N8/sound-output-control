import SwiftUI

struct MenuBarPopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            master
            apps
            Divider1()
            Button { model.openMainWindow?() } label: {
                HStack {
                    Text("Открыть Soundflow").font(.ui(12)).foregroundStyle(Theme.text)
                    Spacer()
                    if let hotkey = model.config.prefs.hotkeys[.openApp] {
                        Text(hotkey.caps.joined()).font(.ui(11)).foregroundStyle(Theme.text3)
                    }
                }
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 348)
        .background(Color(hex: 0x17191D, alpha: 0.95))
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Icon("audio-waveform", size: 16, color: Theme.accent)
            Text("Soundflow").font(.ui(13, .semibold)).foregroundStyle(Theme.text)
            Spacer()
            Menu {
                ForEach(model.config.profiles) { profile in
                    Button {
                        model.profiles.toggle(profile.id)
                    } label: {
                        Text((model.config.activeProfileID == profile.id ? "✓ " : "") + profile.name)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(model.activeProfile == nil ? Theme.text3 : Theme.accent).frame(width: 6, height: 6)
                    Text(model.activeProfile?.name ?? "Без профиля").font(.ui(11)).foregroundStyle(Theme.text)
                    Icon("chevron-down", size: 11, color: Theme.text3)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .card(radius: 6, fill: Theme.surface2)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Button { model.openSettings?() } label: { Icon("settings", size: 15, color: Theme.text2) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 2)
    }

    private var master: some View {
        let devices = Array(model.visibleDevices.prefix(4))
        return VStack(alignment: .leading, spacing: 12) {
            Text("ОСНОВНОЙ ВЫХОД").font(.ui(10, .semibold)).tracking(0.8).foregroundStyle(Theme.text3)
            HStack(spacing: 6) {
                ForEach(devices) { device in
                    let active = device.uid == model.devices.defaultOutputUID
                    Button { model.makeDefault(device.uid) } label: {
                        VStack(spacing: 6) {
                            Icon(device.kind.icon, size: 16, color: active ? Theme.accentInk : Theme.text2)
                            Text(device.shortName).font(.ui(10, .medium)).foregroundStyle(active ? Theme.accentInk : Theme.text2).lineLimit(1)
                        }
                        .padding(.vertical, 10).padding(.horizontal, 4)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 8).fill(active ? Theme.accent : Theme.surface2))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(active ? .clear : Theme.border))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(device.name)
                }
            }
            MasterVolume(sliderWidth: 238)
        }
        .padding(12)
        .card(radius: 10, fill: Theme.bg)
    }

    private var apps: some View {
        let apps = model.apps.sorted { $0.isPlaying && !$1.isPlaying }
        let playing = apps.filter(\.isPlaying).count
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("ПРИЛОЖЕНИЯ").font(.ui(10, .semibold)).tracking(0.8).foregroundStyle(Theme.text3)
                Spacer()
                Text("\(playing) " + plural(playing, "играет", "играют", "играют")).font(.ui(10)).foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 2).padding(.bottom, 4)
            if apps.isEmpty {
                Text("Сейчас ничего не играет").font(.ui(12)).foregroundStyle(Theme.text3).padding(8)
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(apps) { app in MenuBarAppRow(app: app) }
                }
            }
            .frame(maxHeight: 50 * 6 + 20)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MenuBarAppRow: View {
    @Environment(AppModel.self) private var model
    let app: AudioApp
    @State private var hover = false
    @State private var picking = false

    var body: some View {
        let rule = model.rule(app.bundleID)
        let volume = Binding(get: { model.rule(app.bundleID).volume }, set: { model.setVolume(app.bundleID, $0) })
        HStack(spacing: 10) {
            AppIconView(bundleID: app.bundleID, size: 28, dimmed: rule.muted)
                .onTapGesture { model.toggleMute(app.bundleID) }
            VStack(spacing: 5) {
                HStack {
                    Text(app.name).font(.ui(12, .medium)).foregroundStyle(rule.muted ? Theme.text2 : Theme.text).lineLimit(1)
                    Spacer()
                    Text(rule.muted ? "без звука" : percent(rule.volume)).font(.mono(10)).foregroundStyle(rule.muted ? Theme.danger : Theme.text2)
                }
                SFSlider(value: volume, fill: app.isPlaying ? Theme.accent : Theme.text, knob: rule.muted ? Theme.text3 : .white, showsFill: !rule.muted)
            }
            Button { picking = true } label: {
                RoundedRectangle(cornerRadius: 7).fill(Theme.surface2).frame(width: 30, height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
                    .overlay(Icon(rule.outputs.count > 1 ? "git-merge" : rule.outputs.first.map(model.icon(of:)) ?? model.devices.defaultDevice?.kind.icon ?? "speaker",
                                  size: 14, color: rule.outputs.isEmpty ? Theme.text2 : Theme.accent))
            }
            .buttonStyle(.plain)
            .help(model.outputLabel(app.bundleID))
            .popover(isPresented: $picking, arrowEdge: .trailing) {
                OutputMenu(app: app) { picking = false }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover || app.isPlaying && rule.outputs.isEmpty == false ? Theme.surface2.opacity(hover ? 1 : 0.6) : .clear))
        .onHover { hover = $0 }
    }
}

/// The status item icon: waveform, dimmed with a red dot when muted, arrows while switching, alert on error.
struct MenuBarIcon: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let name: String = if case .error = model.engine.health { "triangle-alert" }
            else if model.switchingDevice { "arrow-right-left" }
            else if model.mainMuted { "volume-x" }
            else { "audio-waveform" }
        Image(nsImage: Self.image(name))
    }

    private static func image(_ name: String) -> NSImage {
        guard let source = NSImage(named: "lucide.\(name)") else { return NSImage() }
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }
}
