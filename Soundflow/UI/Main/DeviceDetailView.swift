import SwiftUI

struct DeviceDetailView: View {
    @Environment(AppModel.self) private var model
    let uid: String
    @State private var dropTargeted = false

    var body: some View {
        let device = model.devices.device(uid: uid)
        let known = model.config.knownDevices[uid]
        let name = device?.name ?? known?.name ?? "Устройство"
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 6) {
                    Button("Устройства") { model.selection = nil }.buttonStyle(.sfPlain).foregroundStyle(Theme.text3)
                    Icon("chevron-right", size: 12, color: Theme.text3)
                    Text(name).foregroundStyle(Theme.text2)
                }
                .font(.ui(12))

                DeviceHero(uid: uid, device: device, known: known)

                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 16) {
                        appsOnDevice(device: device, name: name)
                        dropZone(name: name)
                        DeviceHistory(uid: uid)
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: 16) {
                        if let device { DeviceSettingsCard(device: device) }
                        DeviceBehaviorCard(uid: uid, isBluetooth: (device?.transport ?? known?.transport) == .bluetooth)
                    }
                    .frame(width: 380)
                }
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func appsOnDevice(device: AudioDevice?, name: String) -> some View {
        let apps = device == nil ? model.apps.filter { model.rule($0.bundleID).outputs.contains(uid) } : model.apps(on: uid)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Приложения на этом устройстве").font(.ui(14, .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Text(countText(apps.count, "приложение", "приложения", "приложений")).font(.ui(12)).foregroundStyle(Theme.text3)
            }
            if apps.isEmpty {
                Text("Сейчас сюда не выводится звук ни одного приложения.").font(.ui(12)).foregroundStyle(Theme.text3)
                    .padding(.top, 2)
            }
            ForEach(apps) { app in
                DeviceAppRow(app: app, uid: uid)
            }
        }
        .padding(18)
        .card(radius: 12)
    }

    private func dropZone(name: String) -> some View {
        let candidates = model.apps.filter { !model.currentOutputs($0.bundleID).contains(uid) }
        return VStack(spacing: 10) {
            Circle().fill(Theme.surface2).frame(width: 44, height: 44)
                .overlay(Icon("arrow-down-to-line", size: 18, color: dropTargeted ? Theme.accent : Theme.text2))
            Text("Перетащите приложение сюда").font(.ui(13, .medium)).foregroundStyle(Theme.text)
            Text("или выберите из списка — звук сразу пойдёт на \(name)").font(.ui(12)).foregroundStyle(Theme.text3)
            Menu {
                ForEach(candidates) { app in
                    Button(app.name) { model.assign(app.bundleID, to: uid) }
                }
            } label: {
                IconLabel(icon: "plus", title: "Добавить приложение", color: Theme.text2)
            }
            .menuStyle(.button)
            .buttonStyle(.sfSecondary)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(candidates.isEmpty)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .background(RoundedRectangle(cornerRadius: 12).fill(dropTargeted ? Theme.accent.opacity(0.05) : Color.white.opacity(0.016)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(dropTargeted ? Theme.accent : Color.white.opacity(0.13),
                                                                 style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .dropDestination(for: String.self) { items, _ in
            for bundleID in items { model.assign(bundleID, to: uid, additive: NSEvent.modifierFlags.contains(.option)) }
            return true
        } isTargeted: { dropTargeted = $0 }
    }
}

struct DeviceHero: View {
    @Environment(AppModel.self) private var model
    let uid: String
    let device: AudioDevice?
    let known: KnownDevice?

    var body: some View {
        let kind = device?.kind ?? known?.kind ?? .speaker
        let connected = device != nil
        HStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 18).fill(connected ? Theme.accent : Theme.surface2)
                .frame(width: 72, height: 72)
                .overlay(Icon(kind.icon, size: 34, color: connected ? Theme.accentInk : Theme.text3))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(device?.name ?? known?.name ?? "").font(.ui(26, .semibold)).tracking(-0.4).foregroundStyle(Theme.text)
                    if connected {
                        StatusPill(text: uid == model.devices.defaultOutputUID ? "Основное" : "Подключено")
                    } else {
                        StatusPill(text: "Не подключено", color: Theme.danger)
                    }
                }
                Text(specs).font(.ui(13)).foregroundStyle(Theme.text2)
                if let device, let battery = model.battery.battery(for: device.name) {
                    HStack(spacing: 16) {
                        if let left = battery.left { batteryItem("Л \(left)%", left) }
                        if let right = battery.right { batteryItem("П \(right)%", right) }
                        if let main = battery.main { batteryItem("\(main)%", main) }
                        if let caseLevel = battery.caseLevel { batteryItem("Кейс \(caseLevel)%", caseLevel) }
                    }
                }
            }
            Spacer(minLength: 0)
            if let device {
                HStack(spacing: 8) {
                    if uid != model.devices.defaultOutputUID {
                        Button { model.makeDefault(uid) } label: { IconLabel(icon: "star", title: "Сделать основным", color: Theme.text2) }
                            .buttonStyle(.sfSecondary)
                    }
                    Button {
                        model.moveApps(from: uid)
                        if device.transport == .bluetooth { model.battery.disconnect(name: device.name) }
                    } label: {
                        IconLabel(icon: device.transport == .bluetooth ? "bluetooth-off" : "unplug",
                                  title: device.transport == .bluetooth ? "Отключить" : "Освободить", color: Theme.text2)
                    }
                    .buttonStyle(.sfSecondary)
                    .help(device.transport == .bluetooth ? "Отключить устройство и перевести приложения на резервный выход"
                                                         : "Перевести все приложения на резервный выход")
                }
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 14).fill(
                LinearGradient(stops: [.init(color: Theme.accent.opacity(connected ? 0.08 : 0.02), location: 0),
                                       .init(color: Theme.surface, location: 0.6)],
                               startPoint: .leading, endPoint: .trailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }

    private var specs: String {
        guard let device else { return "\(known?.transport.title ?? "") · не в сети" }
        let channels = switch device.outputChannels {
        case 1: "Моно"
        case 2: "Стерео"
        default: "\(device.outputChannels) " + plural(device.outputChannels, "канал", "канала", "каналов")
        }
        var parts = [device.transport.title, device.formatDescription, channels]
        if device.latencyMs > 0.5 { parts.append("задержка ~\(Int(device.latencyMs.rounded())) мс") }
        return parts.joined(separator: " · ")
    }

    private func batteryItem(_ text: String, _ level: Int) -> some View {
        HStack(spacing: 6) {
            Icon(level > 60 ? "battery-full" : "battery-medium", size: 14, color: level < 15 ? Theme.danger : Theme.text2)
            Text(text).font(.mono(11)).foregroundStyle(Theme.text2)
        }
    }
}

struct DeviceAppRow: View {
    @Environment(AppModel.self) private var model
    let app: AudioApp
    let uid: String

    var body: some View {
        let volume = Binding(get: { model.rule(app.bundleID).volume }, set: { model.setVolume(app.bundleID, $0) })
        HStack(spacing: 12) {
            AppIconView(bundleID: app.bundleID, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.ui(13, .medium)).foregroundStyle(Theme.text)
                Text(model.statusText(app).text).font(.ui(11)).foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 0)
            Icon(model.rule(app.bundleID).muted ? "volume-x" : "volume-2", size: 14, color: Theme.text2)
            SFSlider(value: volume).frame(width: 180)
            Text(percent(volume.wrappedValue)).font(.mono(12)).foregroundStyle(Theme.text).frame(width: 28, alignment: .leading)
            Menu {
                Section("Перевести на") {
                    ForEach(model.outputOptions.filter { $0.ref != uid && $0.connected }) { option in
                        Button(option.name) { model.assign(app.bundleID, to: option.ref) }
                    }
                }
            } label: {
                RoundedRectangle(cornerRadius: 8).fill(Theme.surface2).frame(width: 30, height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                    .overlay(Icon("arrow-right-left", size: 14, color: Theme.text2))
            }
            .menuStyle(.button).buttonStyle(.sfPlain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.top, 10)
        .overlay(alignment: .top) { Divider1() }
    }
}

struct DeviceHistory: View {
    @Environment(AppModel.self) private var model
    let uid: String

    var body: some View {
        let events = model.config.history.filter { $0.deviceUID == uid }.suffix(6).reversed()
        let allToday = events.allSatisfy { Calendar.current.isDateInToday($0.date) }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("История").font(.ui(14, .semibold)).foregroundStyle(Theme.text)
                Spacer()
                if !events.isEmpty { Text(allToday ? "Сегодня" : "Недавно").font(.ui(12)).foregroundStyle(Theme.text3) }
            }
            if events.isEmpty {
                Text("Пока ничего не происходило.").font(.ui(12)).foregroundStyle(Theme.text3)
            }
            ForEach(Array(events)) { event in
                HStack(spacing: 12) {
                    Text(event.date.formatted(allToday ? .dateTime.hour().minute() : .dateTime.day().month().hour().minute()))
                        .font(.mono(11)).foregroundStyle(Theme.text3)
                    Icon(icon(event.kind), size: 14, color: Theme.text2)
                    Text(event.text).font(.ui(12)).foregroundStyle(Theme.text2).lineLimit(1)
                    Spacer(minLength: 0)
                    if !event.detail.isEmpty {
                        Text(event.detail).font(.ui(10)).foregroundStyle(Theme.text3)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.surface2))
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 12)
    }

    private func icon(_ kind: HistoryKind) -> String {
        switch kind {
        case .connected, .returned: "plug"
        case .disconnected, .fallback: "unplug"
        case .assigned: "arrow-right-left"
        }
    }
}

struct DeviceSettingsCard: View {
    @Environment(AppModel.self) private var model
    let device: AudioDevice

    var body: some View {
        let volume = Binding(get: { Double(model.devices.device(uid: device.uid)?.volume ?? 0) },
                             set: { model.devices.setVolume(device.uid, Float($0)) })
        let fallback = model.config.settings(for: device.uid).fallbackUID
        let fallbackName = fallback.flatMap { model.devices.device(uid: $0)?.name ?? model.config.knownDevices[$0]?.name } ?? "По приоритету"
        VStack(alignment: .leading, spacing: 14) {
            Text("Настройки устройства").font(.ui(14, .semibold)).foregroundStyle(Theme.text)
            if device.volume != nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("ГРОМКОСТЬ УСТРОЙСТВА").sectionLabelStyle()
                        Spacer()
                        Text(percent(volume.wrappedValue)).font(.mono(12)).foregroundStyle(Theme.text2)
                    }
                    SFSlider(value: volume, fill: Theme.text)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("ФОРМАТ").sectionLabelStyle()
                Menu {
                    Section("Частота") {
                        ForEach(device.availableSampleRates, id: \.self) { rate in
                            Button { model.devices.setSampleRate(device.uid, rate) } label: {
                                Text(rate == device.sampleRate ? "✓ \(rateText(rate))" : rateText(rate))
                            }
                        }
                    }
                    Section("Разрядность") {
                        ForEach([16, 24, 32], id: \.self) { bits in
                            Button(bits == device.bitDepth ? "✓ \(bits) бит" : "\(bits) бит") { model.devices.setBitDepth(device.uid, bits) }
                        }
                    }
                } label: {
                    SelectLabel(icon: "audio-waveform", text: "\(rateText(device.sampleRate)) · \(device.bitDepth) бит · \(device.outputChannels == 1 ? "Моно" : "Стерео")")
                }
                .menuStyle(.button).buttonStyle(.sfPlain).menuIndicator(.hidden)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("РЕЗЕРВНОЕ УСТРОЙСТВО").sectionLabelStyle()
                Menu {
                    Button("По приоритету") { model.updateDevice(device.uid) { $0.fallbackUID = nil } }
                    Divider()
                    ForEach(model.visibleDevices.filter { $0.uid != device.uid }) { other in
                        Button(other.name) { model.updateDevice(device.uid) { $0.fallbackUID = other.uid } }
                    }
                } label: {
                    SelectLabel(icon: fallback.map(model.icon(of:)) ?? "layers", text: fallbackName)
                }
                .menuStyle(.button).buttonStyle(.sfPlain).menuIndicator(.hidden)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 12)
    }

    private func rateText(_ rate: Double) -> String {
        let khz = rate / 1000
        return khz.rounded() == khz ? "\(Int(khz)) кГц" : String(format: "%.1f кГц", khz)
    }
}

/// Select-looking label (icon · value · chevrons).
struct SelectLabel: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Icon(icon, size: 14, color: Theme.text2)
            Text(text).font(.ui(12)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 0)
            Icon("chevrons-up-down", size: 12, color: Theme.text3)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .card(radius: 8, fill: Theme.surface2)
        .contentShape(Rectangle())
    }
}

struct DeviceBehaviorCard: View {
    @Environment(AppModel.self) private var model
    let uid: String
    let isBluetooth: Bool

    var body: some View {
        VStack(spacing: 16) {
            ToggleRow(title: "Автопереключение", subtitle: "Переводить сюда приложения при подключении", isOn: binding(\.autoSwitch))
            if isBluetooth {
                ToggleRow(title: "Избегать режима гарнитуры",
                          subtitle: "Не переключать в HFP — микрофоном остаётся встроенный", isOn: binding(\.avoidHeadsetMode))
            }
            ToggleRow(title: "Скрыть устройство", subtitle: "Не показывать в списках и на карте", isOn: binding(\.hidden))
        }
        .padding(18)
        .card(radius: 12)
    }

    private func binding(_ keyPath: WritableKeyPath<DeviceSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.config.settings(for: uid)[keyPath: keyPath] },
                set: { value in
                    model.updateDevice(uid) { $0[keyPath: keyPath] = value }
                    if keyPath == \.avoidHeadsetMode, value { model.devices.avoidHeadsetInput() }
                    if keyPath == \.hidden, value { model.selection = nil }
                })
    }
}

// MARK: - Multi-output detail

struct MultiOutputDetailView: View {
    @Environment(AppModel.self) private var model
    let id: UUID

    var body: some View {
        if let multi = model.config.multiOutputs.first(where: { $0.id == id }) {
            let apps = model.apps(onMulti: multi)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 6) {
                        Button("Устройства") { model.selection = nil }.buttonStyle(.sfPlain).foregroundStyle(Theme.text3)
                        Icon("chevron-right", size: 12, color: Theme.text3)
                        Text(multi.name).foregroundStyle(Theme.text2)
                    }
                    .font(.ui(12))
                    HStack(spacing: 20) {
                        RoundedRectangle(cornerRadius: 18).fill(Theme.accent).frame(width: 72, height: 72)
                            .overlay(Icon("git-merge", size: 34, color: Theme.accentInk))
                        VStack(alignment: .leading, spacing: 8) {
                            Text(multi.name).font(.ui(26, .semibold)).tracking(-0.4).foregroundStyle(Theme.text)
                            Text("Агрегат · " + multi.deviceUIDs.map(model.name(of:)).joined(separator: " + "))
                                .font(.ui(13)).foregroundStyle(Theme.text2)
                        }
                        Spacer()
                        Button { TestTone.play(on: multi.deviceUIDs) } label: { IconLabel(icon: "play", title: "Проверить звук", color: Theme.text2) }
                            .buttonStyle(.sfSecondary)
                        Button { model.multiOutputDraft = multi } label: { IconLabel(icon: "pencil", title: "Изменить", color: Theme.text2) }
                            .buttonStyle(.sfSecondary)
                    }
                    .padding(22)
                    .card(radius: 14)

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Устройства").font(.ui(14, .semibold)).foregroundStyle(Theme.text)
                            Spacer()
                        }
                        ForEach(multi.deviceUIDs, id: \.self) { uid in
                            let connected = model.devices.isConnected(uid)
                            HStack(spacing: 12) {
                                IconBox(icon: model.icon(of: uid))
                                Text(model.name(of: uid)).font(.ui(13, .medium)).foregroundStyle(Theme.text)
                                if uid == multi.clockUID { Badge(text: "ЧАСЫ") }
                                Spacer()
                                Text(connected ? "Подключено" : "нет связи").font(.ui(11)).foregroundStyle(connected ? Theme.text3 : Theme.danger)
                            }
                        }
                    }
                    .padding(18).card(radius: 12)

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Приложения").font(.ui(14, .semibold)).foregroundStyle(Theme.text)
                        if apps.isEmpty {
                            Text("Назначьте мульти-выход приложению в списке или на карте.").font(.ui(12)).foregroundStyle(Theme.text3)
                        }
                        ForEach(apps) { app in DeviceAppRow(app: app, uid: multi.ref) }
                    }
                    .padding(18).card(radius: 12)
                }
                .padding(28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear.onAppear { model.selection = nil }
        }
    }
}

// MARK: - Toast

struct DisconnectToast: View {
    @Environment(AppModel.self) private var model
    let toast: ToastMessage

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8).fill(Theme.warning.opacity(0.13)).frame(width: 32, height: 32)
                .overlay(Icon(toast.icon, size: 16, color: Theme.warning))
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(.ui(12, .semibold)).foregroundStyle(Theme.text)
                Text(toast.message).font(.ui(11)).foregroundStyle(Theme.text2).lineLimit(2)
            }
            Spacer(minLength: 0)
            if let action = toast.action {
                Button { model.perform(action) } label: {
                    Text("Поставить на паузу").font(.ui(12, .semibold)).foregroundStyle(Color(hex: 0x1F1803))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.warning))
                }
                .buttonStyle(.sfPlain)
            }
            Button { model.toast = nil } label: { Icon("x", size: 14, color: Theme.text3) }.buttonStyle(.sfPlain)
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .frame(maxWidth: 772)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0x2A2416)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.warning.opacity(0.33)))
        .shadow(color: .black.opacity(0.6), radius: 15, y: 12)
        .task(id: toast.id) {
            try? await Task.sleep(for: .seconds(12))
            if model.toast?.id == toast.id { model.toast = nil }
        }
    }
}
