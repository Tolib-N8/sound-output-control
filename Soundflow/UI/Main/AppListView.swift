import SwiftUI

struct AppListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let apps = model.visibleApps
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Приложения").font(.ui(24, .semibold)).tracking(-0.3).foregroundStyle(Theme.text)
                    Text(subtitle).font(.ui(13)).foregroundStyle(Theme.text2)
                }
                Spacer()
                SegmentedControl(selection: $model.filter, items: [
                    .init(value: .all, title: "Все"),
                    .init(value: .playing, title: "Играют"),
                    .init(value: .muted, title: "Без звука"),
                ])
            }

            if model.engine.permission == .denied {
                NoPermissionState()
            } else if case .error = model.engine.health {
                DriverErrorBanner()
            }

            if apps.isEmpty {
                EmptyAppsState(filtered: model.filter != .all || !model.search.isEmpty) {
                    model.filter = .all
                    model.search = ""
                }
                .frame(maxHeight: .infinity)
            } else {
                AppsTable(apps: apps)
                RoutingSummary()
                HStack(alignment: .top, spacing: 8) {
                    Icon("info", size: 13, color: Theme.text3).padding(.top, 1)
                    Text("Новые приложения автоматически используют устройство по умолчанию. Перетащите приложение на устройство в боковой панели, чтобы переназначить вывод.")
                        .font(.ui(11)).foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var subtitle: String {
        let total = model.apps.count
        let playing = model.apps.filter(\.isPlaying).count
        return countText(total, "приложение", "приложения", "приложений") + " · "
            + "\(playing) " + plural(playing, "воспроизводит", "воспроизводят", "воспроизводят") + " звук"
    }
}

struct AppsTable: View {
    @Environment(AppModel.self) private var model
    let apps: [AudioApp]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("ПРИЛОЖЕНИЕ").frame(maxWidth: .infinity, alignment: .leading)
                Text("ГРОМКОСТЬ").frame(width: 232, alignment: .leading)
                Text("ТОЧКА ВЫХОДА").frame(width: 188, alignment: .leading)
                Color.clear.frame(width: 20, height: 1)
            }
            .font(.ui(11, .semibold)).tracking(0.6).foregroundStyle(Theme.text3)
            .padding(.horizontal, 14).padding(.vertical, 10)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        AppRow(app: app, first: index == 0)
                    }
                }
            }
            .frame(maxHeight: 60 * 7)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .card(radius: 12)
    }
}

struct AppRow: View {
    @Environment(AppModel.self) private var model
    let app: AudioApp
    let first: Bool
    @State private var hover = false

    var body: some View {
        let rule = model.rule(app.bundleID)
        let selected = model.selection == .app(app.bundleID)
        let status = model.statusText(app)
        let volume = Binding(get: { model.rule(app.bundleID).volume }, set: { model.setVolume(app.bundleID, $0) })

        HStack(spacing: 16) {
            HStack(spacing: 12) {
                AppIconView(bundleID: app.bundleID, dimmed: rule.muted)
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name).font(.ui(13, .medium)).foregroundStyle(rule.muted ? Theme.text2 : Theme.text).lineLimit(1)
                    AppStatusLine(app: app, text: status.text, tone: status.tone)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 10) {
                MuteButton(muted: rule.muted) { model.toggleMute(app.bundleID) }
                SFSlider(value: volume, fill: selected ? Theme.accent : Theme.text, knob: rule.muted ? Theme.text3 : .white,
                         showsFill: !rule.muted)
                    .frame(width: 144)
                Text(rule.muted ? "—" : percent(rule.volume))
                    .font(.mono(12)).foregroundStyle(rule.muted ? Theme.text3 : Theme.text)
                    .frame(width: 40, alignment: .leading)
            }
            .frame(width: 232)

            OutputPicker(app: app)

            Menu {
                Button("Открыть детали") { model.selection = .app(app.bundleID) }
                Button(rule.muted ? "Включить звук" : "Выключить звук") { model.toggleMute(app.bundleID) }
                Divider()
                Button("Сбросить настройки") { model.resetRule(app.bundleID) }
            } label: {
                Icon("ellipsis", size: 16, color: Theme.text3)
            }
            .menuStyle(.button).buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(width: 20)
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Theme.accent.opacity(0.05) : hover ? Color.white.opacity(0.02) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Theme.accent.opacity(0.2) : .clear))
        .overlay(alignment: .top) {
            if !first && !selected { Rectangle().fill(Theme.border).frame(height: 1).padding(.horizontal, 2) }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.2)) { model.selection = selected ? nil : .app(app.bundleID) }
        }
        .draggable(app.bundleID) {
            HStack(spacing: 8) {
                AppIconView(bundleID: app.bundleID, size: 24)
                Text(app.name).font(.ui(12, .medium)).foregroundStyle(Theme.text)
            }
            .padding(8).card(radius: 8, fill: Theme.surface2)
        }
    }
}

struct AppStatusLine: View {
    @Environment(AppModel.self) private var model
    let app: AudioApp
    let text: String
    let tone: StatusTone

    var body: some View {
        HStack(spacing: 6) {
            switch tone {
            case .playing:
                LiveLevel(level: { model.engine.level(app.bundleID) }) { level in
                    MiniBars(level: model.status(app.bundleID)?.tapped == true ? meterFraction(level) : 0.6)
                }
            case .muted:
                Icon("bell-off", size: 11, color: Theme.text3)
            case .warning:
                Icon("triangle-alert", size: 11, color: Theme.warning)
            case .idle:
                EmptyView()
            }
            Text(text).font(.ui(11)).lineLimit(1)
                .foregroundStyle(tone == .playing ? Theme.text2 : tone == .warning ? Theme.warning : Theme.text3)
        }
    }
}

struct MuteButton: View {
    let muted: Bool
    var size: CGFloat = 28
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 7)
                .fill(muted ? Theme.dangerFill.opacity(0.13) : Theme.surface2)
                .frame(width: size, height: size)
                .overlay(Icon(muted ? "volume-x" : "volume-2", size: 14, color: muted ? Theme.danger : Theme.text2))
        }
        .buttonStyle(.plain)
        .help(muted ? "Включить звук" : "Выключить звук")
    }
}

/// "КАРТА ВЫВОДА · Нагрузка по устройствам" — one card per device with the apps on it.
struct RoutingSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let devices = Array(model.visibleDevices.prefix(4))
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("КАРТА ВЫВОДА", aside: "Нагрузка по устройствам")
            HStack(spacing: 10) {
                ForEach(devices) { device in
                    DeviceLoadCard(device: device)
                }
            }
        }
    }
}

struct DeviceLoadCard: View {
    @Environment(AppModel.self) private var model
    let device: AudioDevice

    var body: some View {
        let apps = model.apps(on: device.uid)
        let active = !apps.isEmpty && apps.contains(where: \.isPlaying)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Icon(device.kind.icon, size: 14, color: active ? Theme.accent : Theme.text2)
                Text(device.name).font(.ui(12, .medium)).foregroundStyle(Theme.text).lineLimit(1)
            }
            HStack {
                HStack(spacing: 4) {
                    ForEach(apps.prefix(4)) { app in
                        AppIconView(bundleID: app.bundleID, size: 24)
                    }
                    if apps.isEmpty { Text("Нет приложений").font(.ui(11)).foregroundStyle(Theme.text3) }
                }
                .frame(height: 24)
                Spacer()
                LiveLevel(level: { apps.map { model.engine.level($0.bundleID) }.max() ?? 0 }) { level in
                    let tapped = apps.contains { model.status($0.bundleID)?.tapped == true }
                    StairBars(level: tapped ? meterFraction(level) : (active ? 0.7 : 0))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 10, stroke: active ? Theme.accent.opacity(0.25) : Theme.border)
        .contentShape(Rectangle())
        .onTapGesture { model.selection = .device(device.uid) }
        .dropDestination(for: String.self) { items, _ in
            for bundleID in items { model.assign(bundleID, to: device.uid, additive: NSEvent.modifierFlags.contains(.option)) }
            return true
        }
    }
}
