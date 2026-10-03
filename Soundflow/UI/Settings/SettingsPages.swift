import AppKit
import SwiftUI
import UserNotifications

// MARK: - Основные

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let prefs = model.config.prefs
        SettingsColumns {
            SettingsGroup(title: "ЗАПУСК") {
                SettingsToggle(title: "Запускать при входе в систему", first: true,
                               isOn: model.pref(\.launchAtLogin) { LoginItem.set($0) })
                SettingsToggle(title: "Значок в строке меню", subtitle: "Быстрый доступ к громкости", isOn: model.pref(\.showMenuBarIcon))
                SettingsToggle(title: "Значок в Dock", isOn: model.pref(\.showDockIcon) { [model] _ in model.applyDockIcon() })
            }
            SettingsGroup(title: "НОВЫЕ ПРИЛОЖЕНИЯ") {
                SettingsRow(title: "Вывод по умолчанию", first: true) {
                    SettingsSelect(icon: prefs.newAppOutput.map(model.icon(of:)) ?? "star",
                                   text: prefs.newAppOutput.map(model.name(of:)) ?? "Основное") {
                        Button("Основное") { model.config.prefs.newAppOutput = nil; model.reconcile() }
                        Divider()
                        ForEach(model.outputOptions.filter(\.connected)) { option in
                            Button(option.name) { model.config.prefs.newAppOutput = option.ref; model.reconcile() }
                        }
                    }
                }
                SettingsRow(title: "Начальная громкость") {
                    HStack(spacing: 10) {
                        SFSlider(value: model.pref(\.newAppVolume)).frame(width: 110)
                        Text(percent(prefs.newAppVolume)).font(.mono(12)).foregroundStyle(Theme.text2).frame(width: 28, alignment: .trailing)
                    }
                }
                SettingsToggle(title: "Спрашивать при первом звуке", subtitle: "Показать окно выбора выхода", isOn: model.pref(\.askOnFirstSound))
            }
            SettingsGroup(title: "ГОРЯЧИЕ КЛАВИШИ") {
                HotkeyRow(title: "Открыть Soundflow", action: .openApp, first: true)
                HotkeyRow(title: "Громче / тише активное приложение", action: .volumeUp, pairedCaps: model.config.prefs.hotkeys[.volumeDown]?.key.label)
                HotkeyRow(title: "Следующее устройство вывода", action: .nextMainDevice)
            }
        } right: {
            SettingsGroup(title: "ПРИОРИТЕТ УСТРОЙСТВ",
                          note: "Если устройство отключилось, звук приложений перейдёт на следующее доступное устройство в списке. Перетаскивайте, чтобы изменить порядок.") {
                DevicePriorityList()
            }
            SettingsGroup(title: "ПОВЕДЕНИЕ") {
                SettingsToggle(title: "Возвращать при подключении", subtitle: "Устройство снова подключилось — звук вернётся",
                               first: true, isOn: model.pref(\.returnOnReconnect))
                SettingsToggle(title: "Приглушать остальных во время звонка",
                               subtitle: "Zoom, FaceTime, Discord — −\(Int(prefs.duckAmount * 100))%", isOn: model.pref(\.duckDuringCalls))
                SettingsToggle(title: "Нормализация громкости", subtitle: "Выравнивать громкость разных приложений", isOn: model.pref(\.normalize))
            }
        }
    }
}

struct DevicePriorityList: View {
    @Environment(AppModel.self) private var model
    @State private var targeted: String?

    var body: some View {
        let priority = model.config.prefs.devicePriority.filter { model.config.knownDevices[$0] != nil }
        ForEach(Array(priority.enumerated()), id: \.element) { index, uid in
            let known = model.config.knownDevices[uid]
            let connected = model.devices.isConnected(uid)
            let builtIn = known?.transport == .builtIn
            HStack(spacing: 12) {
                Icon("grip-vertical", size: 14, color: Theme.text3)
                Text("\(index + 1)").font(.mono(12)).foregroundStyle(Theme.text3).frame(width: 10)
                RoundedRectangle(cornerRadius: 7).fill(index == 0 ? Theme.accent.opacity(0.13) : Theme.surface2).frame(width: 28, height: 28)
                    .overlay(Icon(known?.kind.icon ?? "speaker", size: 14, color: index == 0 ? Theme.accent : Theme.text2))
                Text(known?.name ?? uid).font(.ui(12, .medium)).foregroundStyle(connected ? Theme.text : Theme.text2).lineLimit(1)
                Spacer(minLength: 0)
                if builtIn {
                    Text("всегда доступно").font(.ui(10)).foregroundStyle(Theme.text3)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.surface2))
                } else if !connected {
                    Text("не в сети").font(.ui(10)).foregroundStyle(Theme.text3)
                }
            }
            .padding(.vertical, 11).padding(.horizontal, 14)
            .background(index == 0 ? Color.white.opacity(0.02) : .clear)
            .overlay(alignment: .top) {
                Rectangle().fill(targeted == uid ? Theme.accent : (index == 0 ? .clear : Theme.border)).frame(height: targeted == uid ? 2 : 1)
            }
            .contentShape(Rectangle())
            .draggable(uid)
            .dropDestination(for: String.self) { items, _ in
                guard let moved = items.first, moved != uid else { return false }
                var list = model.config.prefs.devicePriority
                list.removeAll { $0 == moved }
                list.insert(moved, at: list.firstIndex(of: uid) ?? list.endIndex)
                model.config.prefs.devicePriority = list
                model.reconcile()
                return true
            } isTargeted: { targeted = $0 ? uid : (targeted == uid ? nil : targeted) }
        }
    }
}

// MARK: - Hotkeys

struct HotkeyRow: View {
    @Environment(AppModel.self) private var model
    let title: String
    let action: HotkeyAction
    var first = false
    /// Shows e.g. "⌃ ⌥ ↑↓" for a paired up/down action.
    var pairedCaps: String?

    var body: some View {
        SettingsRow(title: title, first: first) {
            HotkeyRecorder(hotkey: model.config.prefs.hotkeys[action], paired: pairedCaps) { hotkey in
                model.config.prefs.hotkeys[action] = hotkey
                model.hotkeys.registerAll()
            }
        }
    }
}

/// Shows a shortcut as key caps; click to record a new one (Esc cancels, ⌫ clears).
struct HotkeyRecorder: View {
    @Environment(AppModel.self) private var model
    let hotkey: Hotkey?
    var paired: String?
    let onChange: (Hotkey?) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            label
            .contentShape(Rectangle())
        }
        .buttonStyle(.sfPlain)
        .help("Нажмите, чтобы изменить сочетание")
        .onDisappear { stop() }
    }

    @ViewBuilder private var label: some View {
        if recording {
            Text("Нажмите сочетание…").font(.ui(11)).foregroundStyle(Theme.accent)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        } else if let hotkey {
            KeyCaps(caps: caps(for: hotkey))
        } else {
            Text("Нажмите сочетание…").font(.ui(11)).foregroundStyle(Theme.text3)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        }
    }

    private func caps(for hotkey: Hotkey) -> [String] {
        var caps = hotkey.caps
        if let paired, !caps.isEmpty { caps[caps.count - 1] += paired }
        return caps
    }

    private func start() {
        recording = true
        model.hotkeys.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = Int(event.keyCode)
            if code == 53 { stop(); return nil } // Esc
            if code == 51 || code == 117 { onChange(nil); stop(); return nil } // ⌫ / ⌦
            var modifiers: Hotkey.Modifiers = []
            if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
            if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
            if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
            if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
            let isFunctionKey = (96...122).contains(code)
            guard !modifiers.isEmpty || isFunctionKey else { NSSound.beep(); return nil }
            onChange(Hotkey(key: .init(code: UInt16(code)), modifiers: modifiers))
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            model.hotkeys.registerAll()
        }
    }
}

struct HotkeySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let devices = model.visibleDevices
        VStack(alignment: .leading, spacing: 22) {
            SettingsColumns {
                SettingsGroup(title: "ОБЩИЕ") {
                    HotkeyRow(title: "Открыть Soundflow", action: .openApp, first: true)
                    HotkeyRow(title: "Открыть карту вывода", action: .openMap)
                    HotkeyRow(title: "Выключить звук всем", action: .muteAll)
                }
                SettingsGroup(title: "АКТИВНОЕ ПРИЛОЖЕНИЕ") {
                    HotkeyRow(title: "Громче", action: .volumeUp, first: true)
                    HotkeyRow(title: "Тише", action: .volumeDown)
                    HotkeyRow(title: "Без звука", action: .muteActive)
                    HotkeyRow(title: "Следующий выход для приложения", action: .nextOutputForActive)
                }
            } right: {
                SettingsGroup(title: "УСТРОЙСТВА") {
                    HotkeyRow(title: "Следующее основное устройство", action: .nextMainDevice, first: true)
                    deviceRow(.switchDevice1, fallbackIndex: 0, devices: devices)
                    deviceRow(.switchDevice2, fallbackIndex: 1, devices: devices)
                }
                SettingsGroup(title: "ПРОФИЛИ") {
                    ForEach(Array(model.config.profiles.enumerated()), id: \.element.id) { index, profile in
                        SettingsRow(title: profile.name, first: index == 0) {
                            HotkeyRecorder(hotkey: profile.hotkey) { hotkey in
                                if let i = model.config.profiles.firstIndex(where: { $0.id == profile.id }) {
                                    model.config.profiles[i].hotkey = hotkey
                                    model.hotkeys.registerAll()
                                }
                            }
                        }
                    }
                }
            }
            Text("Сочетания работают глобально, даже если Soundflow свёрнут. Нажмите на сочетание, чтобы изменить его; ⌫ — удалить. Профильные сочетания только с ⌘ работают, когда Soundflow активен, — чтобы не перехватывать ⌘1–⌘9 у других приложений.")
                .font(.ui(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func deviceRow(_ action: HotkeyAction, fallbackIndex: Int, devices: [AudioDevice]) -> some View {
        let target = model.config.prefs.deviceHotkeyTargets[action] ?? devices.dropFirst(fallbackIndex).first?.uid
        return HStack(spacing: 10) {
            Text("На").font(.ui(12, .medium)).foregroundStyle(Theme.text)
            SettingsSelect(icon: target.map(model.icon(of:)), text: target.map(model.name(of:)) ?? "—", width: 150) {
                ForEach(devices) { device in
                    Button(device.name) { model.config.prefs.deviceHotkeyTargets[action] = device.uid }
                }
            }
            Spacer(minLength: 0)
            HotkeyRecorder(hotkey: model.config.prefs.hotkeys[action]) { hotkey in
                model.config.prefs.hotkeys[action] = hotkey
                model.hotkeys.registerAll()
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .overlay(alignment: .top) { Divider1() }
    }
}

// MARK: - Устройства

struct DeviceSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let prefs = model.config.prefs
        SettingsColumns {
            SettingsGroup(title: "УСТРОЙСТВА ВЫВОДА", note: "Скрытые устройства не показываются в списках и на карте.") {
                let all = model.devices.devices.map { ($0.uid, $0.name, $0.kind.icon, model.deviceSubtitle($0), true) }
                    + model.config.knownDevices.filter { !model.devices.isConnected($0.key) }
                        .map { ($0.key, $0.value.name, $0.value.kind.icon, "\($0.value.transport.title) · не в сети", false) }
                ForEach(Array(all.enumerated()), id: \.element.0) { index, item in
                    let hidden = model.config.settings(for: item.0).hidden
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 7).fill(Theme.surface2).frame(width: 28, height: 28)
                            .overlay(Icon(item.2, size: 14, color: Theme.text2))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.1).font(.ui(12, .medium)).foregroundStyle(item.4 ? Theme.text : Theme.text2).lineLimit(1)
                            Text(item.3).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if !item.4 {
                            Button { forget(item.0) } label: { Icon("trash-2", size: 14, color: Theme.text3) }
                                .buttonStyle(.sfPlain).help("Забыть устройство")
                        }
                        SFSwitch(isOn: Binding(get: { !hidden }, set: { visible in model.updateDevice(item.0) { $0.hidden = !visible } }))
                    }
                    .padding(.vertical, 10).padding(.horizontal, 14)
                    .opacity(item.4 ? 1 : 0.7)
                    .overlay(alignment: .top) { if index > 0 { Divider1() } }
                }
            }
            SettingsGroup(title: "ВИРТУАЛЬНЫЕ УСТРОЙСТВА") {
                ForEach(Array(model.config.multiOutputs.enumerated()), id: \.element.id) { index, multi in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 7).fill(Theme.warning.opacity(0.13)).frame(width: 28, height: 28)
                            .overlay(Icon("git-merge", size: 14, color: Theme.warning))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(multi.name).font(.ui(12, .medium)).foregroundStyle(Theme.text)
                            Text(multi.deviceUIDs.map(model.name(of:)).joined(separator: " + ")).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Button("Изменить") { model.multiOutputDraft = multi }.buttonStyle(.sfSecondary)
                    }
                    .padding(.vertical, 10).padding(.horizontal, 14)
                    .overlay(alignment: .top) { if index > 0 { Divider1() } }
                }
                Button {
                    model.multiOutputDraft = MultiOutput(name: "Колонки + наушники", deviceUIDs: [])
                } label: {
                    HStack(spacing: 8) {
                        Icon("plus", size: 14, color: Theme.accent)
                        Text("Создать мульти-выход").font(.ui(12, .medium)).foregroundStyle(Theme.accent)
                        Spacer()
                    }
                    .padding(.vertical, 12).padding(.horizontal, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.sfPlain)
                .overlay(alignment: .top) { if !model.config.multiOutputs.isEmpty { Divider1() } }
            }
        } right: {
            SettingsGroup(title: "BLUETOOTH") {
                SettingsToggle(title: "Избегать режима гарнитуры", subtitle: "Не переключать наушники в HFP, если микрофон не нужен", first: true,
                               isOn: Binding(get: { model.devices.devices.filter { $0.transport == .bluetooth }.allSatisfy { model.config.settings(for: $0.uid).avoidHeadsetMode } },
                                             set: { value in
                                                 for device in model.devices.devices where device.transport == .bluetooth {
                                                     model.updateDevice(device.uid) { $0.avoidHeadsetMode = value }
                                                 }
                                                 if value { model.devices.avoidHeadsetInput() }
                                             }))
                SettingsToggle(title: "Предупреждать о низком заряде", subtitle: "Уведомить при заряде ниже 15%", isOn: model.pref(\.warnLowBattery))
                SettingsToggle(title: "Показывать заряд в списке", isOn: model.pref(\.showBattery))
            }
            SettingsGroup(title: "ФОРМАТ ЗВУКА", note: "Применяется ко всем устройствам, которые поддерживают выбранный формат.") {
                SettingsRow(title: "Частота", first: true) {
                    SettingsSelect(text: prefs.preferredSampleRate.map { "\(Int($0 / 1000)) кГц" } ?? "Как у устройства") {
                        Button("Как у устройства") { model.config.prefs.preferredSampleRate = nil }
                        ForEach([44100.0, 48000, 88200, 96000, 192000], id: \.self) { rate in
                            Button(rate == 88200 ? "88.2 кГц" : rate == 44100 ? "44.1 кГц" : "\(Int(rate / 1000)) кГц") {
                                model.config.prefs.preferredSampleRate = rate
                                for device in model.devices.devices where device.availableSampleRates.contains(rate) {
                                    model.devices.setSampleRate(device.uid, rate)
                                }
                            }
                        }
                    }
                }
                SettingsRow(title: "Разрядность") {
                    SettingsSelect(text: "\(prefs.bitDepth) бит") {
                        ForEach([16, 24, 32], id: \.self) { bits in
                            Button("\(bits) бит") {
                                model.config.prefs.bitDepth = bits
                                for device in model.devices.devices { model.devices.setBitDepth(device.uid, bits) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func forget(_ uid: String) {
        model.config.knownDevices[uid] = nil
        model.config.devices[uid] = nil
        model.config.prefs.devicePriority.removeAll { $0 == uid }
    }
}

// MARK: - Профили

struct ProfileSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsColumns {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("ПРОФИЛИ").sectionLabelStyle()
                    Spacer()
                    Button {
                        model.profileDraft = Profile(name: "Новый профиль", icon: "sliders-horizontal")
                    } label: { IconLabel(icon: "plus", title: "Новый профиль", color: Theme.accentInk) }
                        .buttonStyle(.sfPrimary)
                }
                ForEach(model.config.profiles) { profile in
                    ProfileCard(profile: profile)
                }
            }
        } right: {
            SettingsGroup(title: "ПЕРЕКЛЮЧЕНИЕ") {
                SettingsToggle(title: "Автовключение", subtitle: "По условиям профиля", first: true,
                               isOn: model.pref(\.autoProfiles) { [model] _ in model.profiles.evaluate() })
                SettingsToggle(title: "Возвращать предыдущий", subtitle: "Когда условие перестало действовать", isOn: model.pref(\.revertProfile))
                SettingsToggle(title: "Уведомление при смене", isOn: model.pref(\.notifyProfileChange) { on in
                    if on { NotificationService.requestAuthorization() }
                })
            }
            SettingsGroup(title: "БЕЗ ПРОФИЛЯ") {
                SettingsRow(title: "Использовать", first: true) {
                    SettingsSelect(text: model.config.prefs.noProfileBehavior == .lastSettings ? "Последние настройки" : "Стандартные", width: 170) {
                        Button("Последние настройки") { model.config.prefs.noProfileBehavior = .lastSettings }
                        Button("Стандартные (сбросить правила)") { model.config.prefs.noProfileBehavior = .defaults }
                    }
                }
            }
        }
    }
}

struct ProfileCard: View {
    @Environment(AppModel.self) private var model
    let profile: Profile

    var body: some View {
        let active = model.config.activeProfileID == profile.id
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9).fill(active ? Theme.accent : Theme.surface2).frame(width: 36, height: 36)
                .overlay(Icon(profile.icon, size: 17, color: active ? Theme.accentInk : Theme.text2))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(profile.name).font(.ui(13, .medium)).foregroundStyle(Theme.text)
                    if active { StatusPill(text: "Активен", color: Theme.accent) }
                }
                Text(summary).font(.ui(11)).foregroundStyle(Theme.text2).lineLimit(1)
                if !profile.activeTriggers.isEmpty {
                    HStack(spacing: 4) {
                        Icon("zap", size: 11, color: Theme.text3)
                        Text(triggerText).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            if let hotkey = profile.hotkey { KeyCap(label: hotkey.caps.joined()) }
            Button { model.profileDraft = profile } label: { Icon("pencil", size: 14, color: Theme.text3) }
                .buttonStyle(.sfPlain).help("Изменить")
            Menu {
                Button(active ? "Выключить" : "Включить") { model.profiles.toggle(profile.id) }
                Button("Дублировать") {
                    var copy = profile
                    copy.id = UUID()
                    copy.name += " (копия)"
                    copy.hotkey = nil
                    model.config.profiles.append(copy)
                }
                Divider()
                Button("Удалить", role: .destructive) {
                    if active { model.profiles.deactivate() }
                    model.config.profiles.removeAll { $0.id == profile.id }
                }
            } label: { Icon("ellipsis", size: 16, color: Theme.text3) }
                .menuStyle(.button).buttonStyle(.sfPlain).menuIndicator(.hidden).fixedSize()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(active ? Theme.accent.opacity(0.04) : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(active ? Theme.accent.opacity(0.3) : Theme.border))
        .contentShape(Rectangle())
        .iconTapTrigger(animate: false)
        .onTapGesture(count: 2) { model.profileDraft = profile }
    }

    private var summary: String {
        var parts: [String] = [profile.mainOutput.map(model.name(of:)) ?? "Основной выход"]
        if let cap = profile.maxVolume { parts.append("громкость ≤ \(percent(cap))%") }
        parts.append(countText(profile.rules.count, "правило", "правила", "правил"))
        return parts.joined(separator: " · ")
    }

    private var triggerText: String {
        profile.activeTriggers.map { trigger in
            switch trigger {
            case .deviceConnected(let uid): "Подключены \(model.name(of: uid))"
            case .appRunning(let bundleID): "Запущен \(AppInfo.name(bundleID))"
            case .wifi(let ssid): "Сеть «\(ssid)»"
            case let .schedule(days, start, end): ProfileTrigger.scheduleText(weekdays: days, start: start, end: end)
            }
        }.joined(separator: ", ")
    }
}

// MARK: - Аудиодрайвер

struct DriverSettings: View {
    @Environment(AppModel.self) private var model
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var showLog = false

    var body: some View {
        let engine = model.engine
        let stats = engine.stats
        let running = engine.health == .running && engine.enabled
        SettingsColumns {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 9).fill(Theme.accent.opacity(0.13)).frame(width: 36, height: 36)
                        .overlay(Icon("cpu", size: 17, color: Theme.accent))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Soundflow Audio Engine").font(.ui(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.8)
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text("Версия \(Bundle.main.shortVersion) · работает \(uptime(stats.startedAt))").font(.ui(11)).foregroundStyle(Theme.text3)
                        }
                    }
                    Spacer()
                    StatusPill(text: running ? "Активен" : engine.enabled ? "Ошибка" : "Выключен", color: running ? Theme.success : Theme.danger)
                }
                HStack(spacing: 8) {
                    stat("Задержка", milliseconds(stats.latencyMs))
                    stat("CPU", "\(Int(stats.cpuPercent.rounded()))%")
                    stat("Потоков", "\(stats.streams)")
                    stat("Сбоев", "\(stats.failures)")
                }
                HStack(spacing: 6) {
                    Button { model.engine.restart() } label: { IconLabel(icon: "rotate-ccw", title: "Перезапустить", color: Theme.text2) }
                        .buttonStyle(.sfSecondary)
                    Button { showLog = true } label: { Icon("file-text", size: 14, color: Theme.text2) }
                        .help("Журнал")
                        .buttonStyle(.sfSecondary)
                        .popover(isPresented: $showLog) { EngineLogView().environment(model) }
                    Spacer()
                    Button {
                        model.engine.enabled.toggle()
                        if model.engine.enabled { model.reconcile() } else { model.engine.shutdown(); model.reconcile() }
                    } label: {
                        IconLabel(icon: model.engine.enabled ? "volume-off" : "play", title: model.engine.enabled ? "Стоп" : "Запустить",
                                  color: model.engine.enabled ? Theme.danger : Theme.text2)
                    }
                    .buttonStyle(model.engine.enabled ? .sfDanger : .sfSecondary)
                    .help("Остановить перехват: все приложения звучат напрямую через macOS")
                }
            }
            .padding(18)
            .card(radius: 12)

            SettingsGroup(title: "МЕТОД ПЕРЕХВАТА") {
                method(title: "Core Audio Process Tap", subtitle: "macOS 14.2+ · без установки драйвера · рекомендуется", selected: true, first: true)
                method(title: "Виртуальный драйвер HAL", subtitle: "Для macOS 13 и старше · требует установки", selected: false)
                    .opacity(0.5)
            }
        } right: {
            SettingsGroup(title: "ПРОИЗВОДИТЕЛЬНОСТЬ", note: "Меньший буфер — ниже задержка, но выше нагрузка на процессор.") {
                SettingsRow(title: "Размер буфера", first: true) {
                    SettingsSelect(text: "\(model.config.prefs.bufferFrames) сэмплов") {
                        ForEach([64, 128, 256, 512, 1024] as [UInt32], id: \.self) { frames in
                            Button("\(frames) сэмплов") { model.config.prefs.bufferFrames = frames; model.reconcile() }
                        }
                    }
                }
                SettingsRow(title: "Качество ресемплинга") {
                    SettingsSelect(text: ["Минимальное", "Низкое", "Среднее", "Высокое", "Максимальное"][model.config.prefs.resamplingQuality.clamped(to: 0...4)]) {
                        ForEach(0..<5) { index in
                            Button(["Минимальное", "Низкое", "Среднее", "Высокое", "Максимальное"][index]) {
                                model.config.prefs.resamplingQuality = index
                                model.reconcile()
                            }
                        }
                    }
                }
                SettingsToggle(title: "Работать в фоне при закрытом окне", isOn: model.pref(\.runInBackground))
            }
            SettingsGroup(title: "РАЗРЕШЕНИЯ") {
                permission("Запись системного звука", icon: "audio-lines", granted: engine.permission == .authorized,
                           pending: engine.permission == .unknown, first: true) {
                    if engine.permission == .unknown {
                        PermissionService.requestAudioCapture { _ in Task { @MainActor in model.engine.refreshPermission(force: true) } }
                    } else {
                        PermissionService.openPrivacySettings()
                    }
                }
                permission("Уведомления", icon: "bell", granted: notificationStatus == .authorized,
                           pending: notificationStatus == .notDetermined) {
                    if notificationStatus == .notDetermined {
                        NotificationService.requestAuthorization { _ in Task { @MainActor in refreshNotifications() } }
                    } else {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                }
            }
        }
        .onAppear(perform: refreshNotifications)
    }

    private func refreshNotifications() {
        NotificationService.status { status in
            Task { @MainActor in notificationStatus = status }
        }
    }

    private func uptime(_ start: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(start) / 60)
        return minutes < 60 ? "\(minutes) мин" : "\(minutes / 60) ч \(minutes % 60) мин"
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.ui(10)).foregroundStyle(Theme.text3)
            Text(value).font(.mono(14, .medium)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 8, fill: Theme.bg)
    }

    private func method(title: String, subtitle: String, selected: Bool, first: Bool = false) -> some View {
        HStack(spacing: 12) {
            RadioDot(selected: selected)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.ui(12, .medium)).foregroundStyle(Theme.text)
                Text(subtitle).font(.ui(11)).foregroundStyle(Theme.text3)
            }
            Spacer()
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(selected ? Theme.accent.opacity(0.04) : .clear)
        .overlay(alignment: .top) { if !first { Divider1() } }
    }

    private func permission(_ title: String, icon: String, granted: Bool, pending: Bool, first: Bool = false, action: @escaping () -> Void) -> some View {
        SettingsRow(title: title, first: first) {
            Button(action: action) {
                StatusPill(text: granted ? "Разрешено" : pending ? "Запросить" : "Не разрешено",
                           color: granted ? Theme.success : Theme.warning)
            }
            .buttonStyle(.sfPlain)
            .disabled(granted)
        }
    }
}

// MARK: - О программе

struct AboutSettings: View {
    @Environment(AppModel.self) private var model
    @State private var showLicenses = false

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88)
                Text("Soundflow").font(.ui(22, .semibold)).foregroundStyle(Theme.text)
                Text("Версия \(Bundle.main.shortVersion) (\(Bundle.main.buildNumber)) · macOS 14.2+").font(.ui(12)).foregroundStyle(Theme.text3)
            }
            .padding(.top, 8)

            SettingsGroup(title: "ОБНОВЛЕНИЯ",
                          note: "Канал обновлений пока не настроен — новые версии устанавливаются вручную.") {
                SettingsRow(title: "Последняя проверка",
                            subtitle: model.config.prefs.lastUpdateCheck.map { $0.formatted(.relative(presentation: .named)) } ?? "Не выполнялась",
                            first: true) {
                    Button("Проверить") { model.config.prefs.lastUpdateCheck = Date() }.buttonStyle(.sfSecondary)
                }
                SettingsToggle(title: "Обновлять автоматически", isOn: model.pref(\.autoUpdate))
                SettingsToggle(title: "Бета-версии", subtitle: "Получать обновления раньше всех", isOn: model.pref(\.betaUpdates))
            }
            .frame(maxWidth: 480)

            HStack(spacing: 18) {
                Button("Лицензии") { showLicenses = true }.buttonStyle(.sfPlain).font(.ui(12)).foregroundStyle(Theme.text2)
                Button("Показать онбординг") { model.openOnboarding?() }.buttonStyle(.sfPlain).font(.ui(12)).foregroundStyle(Theme.text2)
            }
            Text("© 2026 Soundflow. Сделано для тех, кто слушает внимательно.").font(.ui(11)).foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showLicenses) { LicensesView() }
    }
}

struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Лицензии").font(.ui(15, .semibold)).foregroundStyle(Theme.text)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    license("Inter", "SIL Open Font License 1.1 — © The Inter Project Authors", file: "Inter-LICENSE")
                    license("JetBrains Mono", "SIL Open Font License 1.1 — © The JetBrains Mono Project Authors", file: "JetBrainsMono-OFL")
                    license("Lucide Icons", "ISC License — © Lucide Contributors", file: nil)
                }
            }
            HStack { Spacer(); Button("Готово") { dismiss() }.buttonStyle(.sfPrimary) }
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .background(Theme.surface)
    }

    private func license(_ name: String, _ summary: String, file: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.ui(13, .medium)).foregroundStyle(Theme.text)
            Text(summary).font(.ui(11)).foregroundStyle(Theme.text2)
            if let file, let url = Bundle.main.url(forResource: file, withExtension: "txt"), let text = try? String(contentsOf: url, encoding: .utf8) {
                Text(text).font(.mono(10)).foregroundStyle(Theme.text3).textSelection(.enabled)
            }
        }
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
    var buildNumber: String { infoDictionary?["CFBundleVersion"] as? String ?? "1" }
}
