import AppKit
import Observation
import SwiftUI

enum MainMode: String { case list, map }

enum Selection: Hashable {
    case app(String)
    case device(String)
    case multiOutput(UUID)
}

enum AppFilter: String, CaseIterable { case all, playing, muted }

/// A choosable output in pickers: a hardware device, a multi-output or an offline remembered device.
struct OutputOption: Identifiable, Hashable {
    var id: OutputRef { ref }
    let ref: OutputRef
    let name: String
    let icon: String
    let subtitle: String
    let connected: Bool
    let isMulti: Bool
}

struct ToastMessage: Identifiable, Equatable {
    enum Action: Equatable { case pauseUntilReturn(deviceUID: String, apps: [String]) }
    let id = UUID()
    var icon: String
    var title: String
    var message: String
    var action: Action?
}

/// Root state: wires devices, processes, config and the audio engine together and exposes intents for the UI.
@MainActor
@Observable
final class AppModel {
    let store: ConfigStore
    let devices: DeviceManager
    let processes: ProcessMonitor
    let engine: AudioEngine
    let battery: BluetoothInfo
    @ObservationIgnored lazy var profiles = ProfileManager(model: self)
    @ObservationIgnored lazy var hotkeys = HotkeyManager(model: self)

    // UI state
    var mode: MainMode = .list
    var selection: Selection?
    var search = ""
    var filter: AppFilter = .all
    var toast: ToastMessage?
    var multiOutputDraft: MultiOutput?
    var profileDraft: Profile?
    var switchingDevice = false
    var settingsTab: SettingsTab = .general
    /// Bumped whenever the menu bar window opens (drives the status icon animation).
    var menuBarOpenCount = 0
    private(set) var waiting: Set<String> = []
    private(set) var ducked: Set<String> = []

    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored var openSettings: (() -> Void)?
    @ObservationIgnored var openOnboarding: (() -> Void)?
    @ObservationIgnored var didHandleLaunch = false
    @ObservationIgnored var launchAnimationPlayed = false

    var config: Config {
        get { store.config }
        set { store.config = newValue }
    }

    init() {
        store = ConfigStore()
        devices = DeviceManager()
        processes = ProcessMonitor()
        engine = AudioEngine()
        battery = BluetoothInfo()
        if Self.isTesting { engine.enabled = false }

        devices.onDevicesChanged = { [weak self] added, removed in self?.devicesChanged(added: added, removed: removed) }
        devices.onDefaultChanged = { [weak self] in self?.reconcile() }
        processes.onChange = { [weak self] in self?.processesChanged() }
        processes.onAppStartedPlaying = { [weak self] app in self?.appStartedPlaying(app) }
        rememberDevices()
        if config.prefs.devicePriority.isEmpty { config.prefs.devicePriority = defaultPriority() }
        reconcile()
    }

    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func start() {
        guard !Self.isTesting else { return }
        profiles.start()
        hotkeys.registerAll()
        battery.start(model: self)
        applyDockIcon()
    }

    // MARK: - Derived data

    var apps: [AudioApp] { processes.apps }

    var visibleApps: [AudioApp] {
        processes.apps.filter { app in
            let matchesSearch = search.isEmpty || app.name.localizedCaseInsensitiveContains(search)
            let matchesFilter: Bool = switch filter {
            case .all: true
            case .playing: app.isPlaying
            case .muted: rule(app.bundleID).muted
            }
            return matchesSearch && matchesFilter
        }
    }

    var visibleDevices: [AudioDevice] {
        let ordered = config.prefs.devicePriority
        return devices.devices
            .filter { !config.settings(for: $0.uid).hidden }
            .sorted { a, b in
                if a.uid == devices.defaultOutputUID { return true }
                if b.uid == devices.defaultOutputUID { return false }
                return (ordered.firstIndex(of: a.uid) ?? .max) < (ordered.firstIndex(of: b.uid) ?? .max)
            }
    }

    /// Remembered devices that are currently disconnected (and not hidden).
    var offlineDevices: [(uid: String, device: KnownDevice)] {
        config.knownDevices
            .filter { !devices.isConnected($0.key) && !config.settings(for: $0.key).hidden }
            .filter { uid, _ in config.appRules.values.contains { $0.outputs.contains(uid) } || config.prefs.devicePriority.contains(uid) }
            .map { (uid: $0.key, device: $0.value) }
            .sorted { $0.device.name < $1.device.name }
    }

    var outputOptions: [OutputOption] {
        var result = visibleDevices.map { device in
            OutputOption(ref: device.uid, name: device.name, icon: device.kind.icon, subtitle: deviceSubtitle(device),
                         connected: true, isMulti: false)
        }
        result += offlineDevices.map {
            OutputOption(ref: $0.uid, name: $0.device.name, icon: $0.device.kind.icon, subtitle: "Не подключено", connected: false, isMulti: false)
        }
        result += config.multiOutputs.map { multi in
            OutputOption(ref: multi.ref, name: multi.name, icon: "git-merge", subtitle: "\(multi.deviceUIDs.count) устр.",
                         connected: multi.deviceUIDs.contains(where: devices.isConnected), isMulti: true)
        }
        return result
    }

    func rule(_ bundleID: String) -> AppRule {
        config.appRules[bundleID] ?? AppRule(volume: config.prefs.newAppVolume, outputs: config.prefs.newAppOutput.map { [$0] } ?? [])
    }

    func status(_ bundleID: String) -> AudioEngine.AppStatus? { engine.statuses[bundleID] }

    /// Hardware UIDs an app currently plays on.
    func currentOutputs(_ bundleID: String) -> [String] {
        status(bundleID)?.route.outputs ?? devices.defaultOutputUID.map { [$0] } ?? []
    }

    func apps(on uid: String) -> [AudioApp] {
        apps.filter { currentOutputs($0.bundleID).contains(uid) }
    }

    func apps(onMulti multi: MultiOutput) -> [AudioApp] {
        apps.filter { rule($0.bundleID).outputs.contains(multi.ref) }
    }

    func name(of ref: OutputRef) -> String {
        if let multi = config.multiOutput(ref) { return multi.name }
        if let device = devices.device(uid: ref) { return device.name }
        return config.knownDevices[ref]?.name ?? "Устройство"
    }

    func icon(of ref: OutputRef) -> String {
        if ref.isMultiOutput { return "git-merge" }
        if let device = devices.device(uid: ref) { return device.kind.icon }
        return config.knownDevices[ref]?.kind.icon ?? "speaker"
    }

    func deviceSubtitle(_ device: AudioDevice) -> String {
        if device.transport == .bluetooth, config.prefs.showBattery, let level = battery.level(for: device.name) {
            return "Bluetooth · \(level)%"
        }
        if device.transport == .bluetooth { return "Bluetooth" }
        return "\(device.transport.title) · \(device.formatDescription)"
    }

    /// Short label for the app's output, e.g. "AirPods Pro", "По умолчанию", "MacBook · резерв".
    func outputLabel(_ bundleID: String) -> String {
        let rule = rule(bundleID)
        if let status = status(bundleID) {
            switch status.route.status {
            case .fallback: return (devices.device(uid: status.route.outputs.first)?.shortName ?? "—")
            case .waiting(let missing): return name(of: missing.first ?? "")
            default: break
            }
        }
        if rule.outputs.isEmpty { return "По умолчанию" }
        if rule.outputs.count > 1 { return "Мульти-выход" }
        return name(of: rule.outputs[0])
    }

    var mainVolume: Float {
        get { devices.defaultDevice?.volume ?? 0 }
        set { if let uid = devices.defaultOutputUID { devices.setVolume(uid, newValue) } }
    }

    var mainMuted: Bool { devices.defaultDevice?.muted ?? false }

    var activeProfile: Profile? { config.profiles.first { $0.id == config.activeProfileID } }

    // MARK: - Intents: apps

    func updateRule(_ bundleID: String, _ change: (inout AppRule) -> Void) {
        var rule = rule(bundleID)
        change(&rule)
        config.appRules[bundleID] = rule
        reconcile()
    }

    func setVolume(_ bundleID: String, _ volume: Double) {
        updateRule(bundleID) {
            $0.volume = max(0, min(1, volume))
            if volume > 0 { $0.muted = false }
        }
    }

    func toggleMute(_ bundleID: String) { updateRule(bundleID) { $0.muted.toggle() } }

    func setBalance(_ bundleID: String, _ balance: Double) { updateRule(bundleID) { $0.balance = max(-1, min(1, balance)) } }

    /// Assigns an output. With `additive`, adds/removes it alongside existing outputs.
    func assign(_ bundleID: String, to ref: OutputRef?, additive: Bool = false) {
        updateRule(bundleID) { rule in
            guard let ref else { rule.outputs = []; return }
            if additive {
                let current = rule.outputs.isEmpty ? (devices.defaultOutputUID.map { [$0] } ?? []) : rule.outputs
                if current.contains(ref) {
                    rule.outputs = current.filter { $0 != ref }
                } else {
                    rule.outputs = current + [ref]
                }
            } else {
                rule.outputs = [ref]
            }
        }
        waiting.remove(bundleID)
        if let ref, !ref.isMultiOutput {
            log(ref, .assigned, "\(AppInfo.name(bundleID)) назначен вручную", detail: mode == .map ? "на карте" : "в списке")
        }
    }

    func resetRule(_ bundleID: String) {
        config.appRules[bundleID] = nil
        reconcile()
    }

    func muteAll() {
        guard let uid = devices.defaultOutputUID else { return }
        devices.setMuted(uid, !mainMuted)
    }

    // MARK: - Intents: devices

    func makeDefault(_ uid: String) {
        devices.setDefault(uid)
        flashSwitching()
        reconcile()
    }

    func updateDevice(_ uid: String, _ change: (inout DeviceSettings) -> Void) {
        var settings = config.settings(for: uid)
        change(&settings)
        config.devices[uid] = settings
        reconcile()
    }

    func nextMainDevice() {
        let list = visibleDevices
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.uid == devices.defaultOutputUID } ?? -1
        makeDefault(list[(index + 1) % list.count].uid)
    }

    /// Moves every app off a device (used by "Отключить").
    func moveApps(from uid: String) {
        let target = RouteResolver.fallbackDevice(rule: AppRule(), excluding: [uid], config: config,
                                                  connected: Set(devices.devices.map(\.uid)), defaultUID: devices.defaultOutputUID)
        for app in apps(on: uid) {
            updateRule(app.bundleID) { $0.outputs = target.map { [$0] } ?? [] }
        }
        if devices.defaultOutputUID == uid, let target { makeDefault(target) }
    }

    // MARK: - Intents: multi-outputs

    func saveMultiOutput(_ multi: MultiOutput) {
        if let index = config.multiOutputs.firstIndex(where: { $0.id == multi.id }) {
            config.multiOutputs[index] = multi
        } else {
            config.multiOutputs.append(multi)
        }
        reconcile()
    }

    func deleteMultiOutput(_ id: UUID) {
        let ref = OutputRef.multiPrefix + id.uuidString
        config.multiOutputs.removeAll { $0.id == id }
        for (bundleID, rule) in config.appRules where rule.outputs.contains(ref) {
            config.appRules[bundleID]?.outputs.removeAll { $0 == ref }
        }
        reconcile()
    }

    // MARK: - Engine sync

    func reconcile() {
        updateDucking()
        engine.reconcile(.init(
            apps: processes.apps,
            config: config,
            devices: devices.devices,
            defaultUID: devices.defaultOutputUID,
            ducked: ducked,
            waiting: waiting,
            volumeCap: activeProfile?.maxVolume
        ))
    }

    static let callApps: Set<String> = [
        "us.zoom.xos", "com.apple.FaceTime", "com.hnc.Discord", "com.microsoft.teams2", "com.microsoft.teams",
        "com.tinyspeck.slackmacgap", "ru.keepcoder.Telegram", "org.telegram.desktop", "com.skype.skype",
        "com.cisco.webexmeetingsapp", "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
        "org.mozilla.firefox", "com.microsoft.edgemac", "net.whatsapp.WhatsApp", "com.apple.mobilephone",
    ]

    var appsInCall: [AudioApp] { apps.filter { $0.isUsingInput && Self.callApps.contains($0.bundleID) } }

    private func updateDucking() {
        guard config.prefs.duckDuringCalls else { ducked = []; return }
        let callers = Set(appsInCall.map(\.bundleID))
        guard !callers.isEmpty else { ducked = []; return }
        ducked = Set(apps.map(\.bundleID).filter { !callers.contains($0) && rule($0).duckDuringCalls })
    }

    private func processesChanged() {
        // Forget non-remembered rules once their app has quit.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for (bundleID, rule) in config.appRules where !rule.remember && !running.contains(bundleID) {
            config.appRules[bundleID] = nil
        }
        processes.apps.forEach(AppInfo.remember)
        reconcile()
        profiles.evaluate()
    }

    private func appStartedPlaying(_ app: AudioApp) {
        guard config.prefs.askOnFirstSound, config.appRules[app.bundleID] == nil else { return }
        FirstSoundPanel.show(app: app, model: self)
    }

    // MARK: - Device events

    private func devicesChanged(added: [AudioDevice], removed: [AudioDevice]) {
        let previous = engine.statuses
        rememberDevices()

        for device in removed {
            let affected = apps.filter { app in previous[app.bundleID]?.route.outputs.contains(device.uid) == true && !(previous[app.bundleID]?.route.followsDefault ?? true) }
            log(device.uid, .disconnected, "Отключены", detail: affected.isEmpty ? "" : "резерв")
            reconcile()
            guard !affected.isEmpty else { continue }
            let fallback = affected.compactMap { engine.statuses[$0.bundleID]?.route.outputs.first }.first
            let fallbackName = fallback.flatMap { devices.device(uid: $0)?.name } ?? "устройство по умолчанию"
            let names = affected.map(\.name).formatted(.list(type: .and))
            if let index = config.history.lastIndex(where: { $0.deviceUID == device.uid && $0.kind == .disconnected }) {
                config.history[index].text = "Отключены — звук ушёл на \(fallbackName)"
            }
            let keepRules = config.prefs.returnOnReconnect && config.settings(for: device.uid).autoSwitch
            if !keepRules, let fallback {
                for app in affected { config.appRules[app.bundleID]?.outputs = [fallback] }
            }
            toast = ToastMessage(
                icon: "bluetooth-off",
                title: "\(device.name) отключены",
                message: "\(names) переведены на \(fallbackName)." + (keepRules ? " Вернём их, когда \(device.shortName) подключатся." : ""),
                action: .pauseUntilReturn(deviceUID: device.uid, apps: affected.map(\.bundleID))
            )
            NotificationService.post(title: "\(device.name) отключены", body: "\(names) переведены на \(fallbackName)")
        }

        for device in added {
            waiting = waiting.filter { bundleID in !rule(bundleID).outputs.contains(device.uid) }
            let returning = apps.filter { rule($0.bundleID).outputs.contains(device.uid) }
            if !returning.isEmpty {
                log(device.uid, .connected, "Подключены — \(returning.map(\.name).formatted(.list(type: .and))) переведены сюда", detail: "автопереключение")
            } else {
                log(device.uid, .connected, "Подключены", detail: "")
            }
            if device.transport == .bluetooth, config.settings(for: device.uid).avoidHeadsetMode {
                devices.avoidHeadsetInput()
            }
            if toast?.title.hasPrefix(device.name) == true { toast = nil }
        }
        if !added.isEmpty || !removed.isEmpty { flashSwitching() }
        reconcile()
        profiles.evaluate()
    }

    func perform(_ action: ToastMessage.Action) {
        switch action {
        case let .pauseUntilReturn(uid, apps):
            waiting.formUnion(apps)
            // Rules may have been moved to the fallback; point them back at the missing device.
            for bundleID in apps where !rule(bundleID).outputs.contains(uid) {
                config.appRules[bundleID, default: rule(bundleID)].outputs = [uid]
            }
            reconcile()
        }
        toast = nil
    }

    func log(_ uid: String, _ kind: HistoryKind, _ text: String, detail: String) {
        config.history.append(HistoryEvent(date: Date(), deviceUID: uid, kind: kind, text: text, detail: detail))
        if config.history.count > 300 { config.history.removeFirst(config.history.count - 300) }
    }

    private func rememberDevices() {
        for device in devices.devices {
            let known = KnownDevice(name: device.name, transport: device.transport, kind: device.kind)
            if config.knownDevices[device.uid] != known { config.knownDevices[device.uid] = known }
            if !config.prefs.devicePriority.contains(device.uid), !config.prefs.devicePriority.isEmpty {
                // New devices go before the built-in speakers, which stay as the last resort.
                let builtIn = config.prefs.devicePriority.firstIndex { config.knownDevices[$0]?.transport == .builtIn }
                config.prefs.devicePriority.insert(device.uid, at: builtIn ?? config.prefs.devicePriority.endIndex)
            }
        }
    }

    private func defaultPriority() -> [String] {
        devices.devices.sorted { a, b in
            let rank: (AudioDevice) -> Int = { $0.transport == .builtIn ? 2 : ($0.kind == .headphones ? 0 : 1) }
            return rank(a) < rank(b)
        }.map(\.uid)
    }

    private func flashSwitching() {
        switchingDevice = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { self?.switchingDevice = false }
        }
    }

    #if DEBUG
    /// Developer aid: `-SFScreen map|app|device|multi|profile|menubar|settings:<tab>|onboarding:<step>` opens a screen on launch.
    var debugScreen: String? { UserDefaults.standard.string(forKey: "SFScreen") }

    func applyDebugScreen() {
        guard let screen = debugScreen else { return }
        let parts = screen.split(separator: ":").map(String.init)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            switch parts[0] {
            case "map": mode = .map
            case "app": selection = apps.first.map { .app($0.bundleID) }
            case "device": selection = visibleDevices.first.map { .device($0.uid) }
            case "multi": multiOutputDraft = MultiOutput(name: "Колонки + наушники", deviceUIDs: visibleDevices.prefix(2).map(\.uid))
            case "profile": profileDraft = config.profiles.first
            case "settings":
                settingsTab = parts.count > 1 ? SettingsTab(rawValue: parts[1]) ?? .general : .general
                openSettings?()
            case "onboarding": openOnboarding?()
            case "tour":
                // Walks through the scenes to preview transitions: list → map → device → list.
                let steps: [(Double, @MainActor () -> Void)] = [
                    (2.0, { self.mode = .map }),
                    (4.0, { self.selection = self.visibleDevices.first.map { .device($0.uid) } }),
                    (6.0, { self.selection = nil; self.mode = .list }),
                ]
                for (delay, step) in steps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { step() } }
                }
            case "toast":
                toast = ToastMessage(icon: "bluetooth-off", title: "AirPods Pro отключены",
                                     message: "Spotify и Discord переведены на MacBook Pro. Вернём их, когда AirPods подключатся.",
                                     action: .pauseUntilReturn(deviceUID: "", apps: []))
            default: break
            }
        }
    }
    #endif

    // MARK: - App chrome

    func applyDockIcon() {
        NSApp.setActivationPolicy(config.prefs.showDockIcon ? .regular : .accessory)
    }

    func shutdown() {
        store.saveNow()
        engine.shutdown()
    }
}
