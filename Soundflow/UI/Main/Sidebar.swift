import SwiftUI
import UniformTypeIdentifiers

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                header("УСТРОЙСТВА ВЫВОДА", help: "Создать мульти-выход") {
                    model.multiOutputDraft = MultiOutput(name: "Колонки + наушники", deviceUIDs: [])
                }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(model.visibleDevices) { device in
                            SidebarDeviceRow(device: device)
                        }
                        ForEach(model.offlineDevices, id: \.uid) { item in
                            SidebarOfflineRow(uid: item.uid, device: item.device)
                        }
                        ForEach(model.config.multiOutputs) { multi in
                            SidebarMultiRow(multi: multi)
                        }
                    }
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 2) {
                header("ПРОФИЛИ", help: "Новый профиль") {
                    model.profileDraft = Profile(name: "Новый профиль", icon: "sliders-horizontal")
                }
                .padding(.bottom, 4)
                ForEach(model.config.profiles) { profile in
                    SidebarProfileRow(profile: profile)
                }
            }

            Spacer(minLength: 0)
            UpdatePill()
            EngineStatusCard()
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 14)
        .frame(width: 272)
        .frame(maxHeight: .infinity)
        .background(Theme.surface)
        .hairline(.trailing)
    }

    private func header(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title).sectionLabelStyle()
            Spacer()
            Button(action: action) { Icon("plus", size: 14, color: Theme.text3) }
                .buttonStyle(.sfPlain)
                .help(help)
        }
        .padding(.horizontal, 8)
    }
}

private struct SidebarRow<Trailing: View>: View {
    let icon: String
    let name: String
    let subtitle: String
    var badge: String?
    var highlighted = false
    var dimmed = false
    var subtitleColor: Color = Theme.text3
    @ViewBuilder var trailing: Trailing
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            IconBox(icon: icon, active: highlighted)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.ui(13, .medium)).foregroundStyle(dimmed ? Theme.text2 : Theme.text).lineLimit(1)
                    if let badge { Badge(text: badge) }
                }
                Text(subtitle).font(.ui(11)).foregroundStyle(subtitleColor).lineLimit(1)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.vertical, 9).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 9).fill(highlighted ? Theme.surface2 : hover ? Theme.surface2.opacity(0.5) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(highlighted ? Theme.border : .clear))
        .opacity(dimmed ? 0.6 : 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

struct SidebarDeviceRow: View {
    @Environment(AppModel.self) private var model
    let device: AudioDevice
    @State private var targeted = false

    var body: some View {
        let count = model.listedApps(on: device.uid).count
        let highlighted = isHighlighted
        SidebarRow(icon: device.kind.icon, name: device.name, subtitle: model.deviceSubtitle(device),
                   badge: device.uid == model.devices.defaultOutputUID ? "ОСН" : nil, highlighted: highlighted) {
            if count > 0 {
                Text("\(count)").font(.mono(11)).foregroundStyle(highlighted ? Theme.accent : Theme.text3)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.accent, lineWidth: targeted ? 1.5 : 0))
        .iconTap { model.selection = .device(device.uid) }
        .contextMenu {
            Button("Сделать основным") { model.makeDefault(device.uid) }
            Button("Открыть детали") { model.selection = .device(device.uid) }
            Button("Скрыть устройство") { model.updateDevice(device.uid) { $0.hidden = true } }
        }
        .dropDestination(for: String.self) { items, _ in
            for bundleID in items { model.assign(bundleID, to: device.uid, additive: NSEvent.modifierFlags.contains(.option)) }
            return !items.isEmpty
        } isTargeted: { targeted = $0 }
    }

    private var isHighlighted: Bool {
        switch model.selection {
        case .device(let uid): return uid == device.uid
        case .app(let bundleID): return model.currentOutputs(bundleID).contains(device.uid)
        default: return false
        }
    }
}

struct SidebarOfflineRow: View {
    @Environment(AppModel.self) private var model
    let uid: String
    let device: KnownDevice

    var body: some View {
        let count = model.config.appRules.values.filter { $0.outputs.contains(uid) }.count
        SidebarRow(icon: device.kind.icon, name: device.name, subtitle: "Не подключено", dimmed: true, subtitleColor: Theme.danger) {
            if count > 0 { Text("\(count)").font(.mono(11)).foregroundStyle(Theme.text3) }
        }
        .iconTap { model.selection = .device(uid) }
    }
}

struct SidebarMultiRow: View {
    @Environment(AppModel.self) private var model
    let multi: MultiOutput
    @State private var targeted = false

    var body: some View {
        let count = model.listedApps(onMulti: multi).count
        let selected = model.selection == .multiOutput(multi.id)
        SidebarRow(icon: "git-merge", name: multi.name,
                   subtitle: "Агрегат · " + countText(multi.deviceUIDs.count, "устройство", "устройства", "устройств"),
                   highlighted: selected) {
            if count > 0 { Text("\(count)").font(.mono(11)).foregroundStyle(Theme.text3) }
        }
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.accent, lineWidth: targeted ? 1.5 : 0))
        .iconTap { model.selection = .multiOutput(multi.id) }
        .contextMenu {
            Button("Изменить…") { model.multiOutputDraft = multi }
            Button("Удалить", role: .destructive) { model.deleteMultiOutput(multi.id) }
        }
        .dropDestination(for: String.self) { items, _ in
            for bundleID in items { model.assign(bundleID, to: multi.ref) }
            return !items.isEmpty
        } isTargeted: { targeted = $0 }
    }
}

struct SidebarProfileRow: View {
    @Environment(AppModel.self) private var model
    let profile: Profile
    @State private var hover = false

    var body: some View {
        let active = model.config.activeProfileID == profile.id
        HStack(spacing: 10) {
            Icon(profile.icon, size: 15, color: active ? Theme.accent : Theme.text2)
            Text(profile.name).font(.ui(13, active ? .medium : .regular)).foregroundStyle(active ? Theme.text : Theme.text2)
            Spacer(minLength: 0)
            if active { Circle().fill(Theme.accent).frame(width: 6, height: 6) }
            if let hotkey = profile.hotkey {
                Text(hotkey.caps.joined()).font(.mono(11)).foregroundStyle(Theme.text3)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Theme.surface2.opacity(0.6) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .iconTap { model.profiles.toggle(profile.id) }
        .contextMenu {
            Button(active ? "Выключить" : "Включить") { model.profiles.toggle(profile.id) }
            Button("Изменить…") { model.profileDraft = profile }
        }
    }
}

/// Shown above the engine status when an update is available or ready.
struct UpdatePill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let update = model.updater.availableUpdate {
            let ready: Bool = if case .ready = model.updater.state { true } else { false }
            Button {
                if ready { model.updater.installAndRelaunch() } else {
                    model.settingsTab = .about
                    model.openSettings?()
                }
            } label: {
                HStack(spacing: 10) {
                    Icon(ready ? "rotate-ccw" : "arrow-down-to-line", size: 14, color: Theme.accentInk)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ready ? "Перезапустить для обновления" : "Доступно обновление").font(.ui(12, .semibold))
                        Text("Soundflow \(update.version)").font(.mono(10))
                    }
                    .foregroundStyle(Theme.accentInk)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent))
            }
            .buttonStyle(.sfPlain)
            .padding(.bottom, -14)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

struct EngineStatusCard: View {
    @Environment(AppModel.self) private var model
    @State private var countdown = 3

    var body: some View {
        let (color, title, subtitle) = describe()
        Button { model.openSettings?() } label: {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 8, height: 8)
                    .shadow(color: color.opacity(0.6), radius: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.ui(12, .medium)).foregroundStyle(Theme.text)
                    Text(subtitle).font(.mono(10)).foregroundStyle(Theme.text3)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .card(radius: 10, fill: Theme.bg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.sfPlain)
    }

    private func describe() -> (Color, String, String) {
        let stats = model.engine.stats
        switch model.engine.health {
        case .running:
            return (Theme.success, "Аудио-драйвер активен",
                    "Задержка \(milliseconds(stats.latencyMs)) · CPU \(Int(stats.cpuPercent.rounded()))%")
        case .restarting:
            return (Theme.warning, "Перезапуск драйвера", "Переподключение…")
        case .permissionNeeded:
            return (Theme.warning, "Нет доступа к звуку", "Разрешите запись звука")
        case .error:
            return (Theme.danger, "Драйвер остановлен", "Переподключение через 3 с…")
        }
    }
}
