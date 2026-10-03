import Foundation

/// Output target reference: a hardware device UID or a Soundflow multi-output (`multi:<uuid>`).
typealias OutputRef = String

extension OutputRef {
    static let multiPrefix = "multi:"
    var isMultiOutput: Bool { hasPrefix(Self.multiPrefix) }
    var multiOutputID: UUID? { isMultiOutput ? UUID(uuidString: String(dropFirst(Self.multiPrefix.count))) : nil }
}

/// Per-application settings.
struct AppRule: Codable, Equatable, Sendable {
    var volume: Double = 1
    var muted = false
    var balance: Double = 0
    /// Empty = follow the system default output.
    var outputs: [OutputRef] = []
    var remember = true
    /// When off, the app is paused (silenced) until its device returns instead of moving to a fallback.
    var useFallback = true
    /// Explicit fallback device; nil = use the device priority list.
    var fallbackUID: String?
    var duckDuringCalls = true

    init(volume: Double = 1, muted: Bool = false, outputs: [OutputRef] = []) {
        self.volume = volume
        self.muted = muted
        self.outputs = outputs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volume = try c.decode(Double.self, forKey: .volume, default: 1)
        muted = try c.decode(Bool.self, forKey: .muted, default: false)
        balance = try c.decode(Double.self, forKey: .balance, default: 0)
        outputs = try c.decode([OutputRef].self, forKey: .outputs, default: [])
        remember = try c.decode(Bool.self, forKey: .remember, default: true)
        useFallback = try c.decode(Bool.self, forKey: .useFallback, default: true)
        fallbackUID = try c.decodeIfPresent(String.self, forKey: .fallbackUID)
        duckDuringCalls = try c.decode(Bool.self, forKey: .duckDuringCalls, default: true)
    }

    var isDefault: Bool { volume == 1 && !muted && balance == 0 && outputs.isEmpty }
}

/// User settings for a hardware device, keyed by UID.
struct DeviceSettings: Codable, Equatable, Sendable {
    var hidden = false
    /// Move apps assigned to this device back when it reconnects.
    var autoSwitch = true
    var fallbackUID: String?
    var avoidHeadsetMode = true
    var compensateLatency = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hidden = try c.decode(Bool.self, forKey: .hidden, default: false)
        autoSwitch = try c.decode(Bool.self, forKey: .autoSwitch, default: true)
        fallbackUID = try c.decodeIfPresent(String.self, forKey: .fallbackUID)
        avoidHeadsetMode = try c.decode(Bool.self, forKey: .avoidHeadsetMode, default: true)
        compensateLatency = try c.decode(Bool.self, forKey: .compensateLatency, default: false)
    }
}

/// A device seen before, remembered so it can be listed while offline.
struct KnownDevice: Codable, Equatable, Sendable {
    var name: String
    var transport: DeviceTransport
    var kind: DeviceKind
}

/// A virtual output that plays on several devices at once.
struct MultiOutput: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var deviceUIDs: [String]
    var clockUID: String?
    /// Delay faster devices so all outputs line up.
    var alignLatency = true
    var driftCorrection = true
    /// Manual extra delay per device in milliseconds.
    var delays: [String: Double] = [:]

    var ref: OutputRef { OutputRef.multiPrefix + id.uuidString }
}

enum ProfileTrigger: Codable, Equatable, Hashable, Sendable {
    case deviceConnected(uid: String)
    case schedule(weekdays: Set<Int>, start: Int, end: Int)
    case appRunning(bundleID: String)
    case wifi(ssid: String)
}

struct ProfileAppRule: Codable, Equatable, Sendable, Identifiable {
    var id: String { bundleID }
    var bundleID: String
    var volume: Double = 1
    var muted = false
    var output: OutputRef?
}

struct Profile: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var icon: String
    var hotkey: Hotkey?
    var mainOutput: OutputRef?
    var rules: [ProfileAppRule] = []
    var othersVolume: Double = 1
    var othersOutput: OutputRef?
    var maxVolume: Double?
    var triggers: [ProfileTrigger] = []
    var enabledTriggers: Set<Int> = []

    var activeTriggers: [ProfileTrigger] {
        triggers.enumerated().filter { enabledTriggers.contains($0.offset) }.map(\.element)
    }
}

enum HistoryKind: String, Codable, Sendable {
    case connected, disconnected, assigned, fallback, returned
}

struct HistoryEvent: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var date: Date
    var deviceUID: String
    var kind: HistoryKind
    var text: String
    var detail: String
}

enum HotkeyAction: String, Codable, CaseIterable, Sendable {
    case openApp, openMap, muteAll
    case volumeUp, volumeDown, muteActive, nextOutputForActive
    case nextMainDevice, switchDevice1, switchDevice2
}

enum NoProfileBehavior: String, Codable, Sendable { case lastSettings, defaults }

struct Preferences: Codable, Equatable, Sendable {
    var onboardingDone = false
    var launchAtLogin = false
    var showMenuBarIcon = true
    var showDockIcon = true
    var newAppOutput: OutputRef?
    var newAppVolume: Double = 1
    var askOnFirstSound = false
    var devicePriority: [String] = []
    var returnOnReconnect = true
    var duckDuringCalls = true
    var duckAmount: Double = 0.6
    var normalize = false
    var warnLowBattery = true
    var showBattery = true
    var preferredSampleRate: Double?
    var bitDepth = 24
    var matchSourceSampleRate = false
    var autoProfiles = true
    var revertProfile = true
    var notifyProfileChange = false
    var noProfileBehavior = NoProfileBehavior.lastSettings
    var bufferFrames: UInt32 = 256
    var resamplingQuality = 2
    var runInBackground = true
    var autoUpdate = true
    var betaUpdates = false
    var lastUpdateCheck: Date?
    var hotkeys: [HotkeyAction: Hotkey] = Preferences.defaultHotkeys
    var deviceHotkeyTargets: [HotkeyAction: String] = [:]
    /// Apps the user removed from the lists (their rules still apply).
    var hiddenApps: [String] = []
    /// Also list apps that have an audio client but haven't made a sound yet (e.g. Terminal).
    var showIdleApps = false

    static let defaultHotkeys: [HotkeyAction: Hotkey] = [
        .openApp: Hotkey(key: .s, modifiers: [.option, .command]),
        .openMap: Hotkey(key: .m, modifiers: [.option, .command]),
        .muteAll: Hotkey(key: .m, modifiers: [.control, .option]),
        .volumeUp: Hotkey(key: .up, modifiers: [.control, .option]),
        .volumeDown: Hotkey(key: .down, modifiers: [.control, .option]),
        .nextOutputForActive: Hotkey(key: .right, modifiers: [.control, .option]),
        .nextMainDevice: Hotkey(key: .o, modifiers: [.control, .option]),
        .switchDevice1: Hotkey(key: .one, modifiers: [.control, .option]),
        .switchDevice2: Hotkey(key: .two, modifiers: [.control, .option]),
    ]

    init() {}

    init(from decoder: Decoder) throws {
        let d = Preferences()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        onboardingDone = try c.decode(Bool.self, forKey: .onboardingDone, default: d.onboardingDone)
        launchAtLogin = try c.decode(Bool.self, forKey: .launchAtLogin, default: d.launchAtLogin)
        showMenuBarIcon = try c.decode(Bool.self, forKey: .showMenuBarIcon, default: d.showMenuBarIcon)
        showDockIcon = try c.decode(Bool.self, forKey: .showDockIcon, default: d.showDockIcon)
        newAppOutput = try c.decodeIfPresent(OutputRef.self, forKey: .newAppOutput)
        newAppVolume = try c.decode(Double.self, forKey: .newAppVolume, default: d.newAppVolume)
        askOnFirstSound = try c.decode(Bool.self, forKey: .askOnFirstSound, default: d.askOnFirstSound)
        devicePriority = try c.decode([String].self, forKey: .devicePriority, default: d.devicePriority)
        returnOnReconnect = try c.decode(Bool.self, forKey: .returnOnReconnect, default: d.returnOnReconnect)
        duckDuringCalls = try c.decode(Bool.self, forKey: .duckDuringCalls, default: d.duckDuringCalls)
        duckAmount = try c.decode(Double.self, forKey: .duckAmount, default: d.duckAmount)
        normalize = try c.decode(Bool.self, forKey: .normalize, default: d.normalize)
        warnLowBattery = try c.decode(Bool.self, forKey: .warnLowBattery, default: d.warnLowBattery)
        showBattery = try c.decode(Bool.self, forKey: .showBattery, default: d.showBattery)
        preferredSampleRate = try c.decodeIfPresent(Double.self, forKey: .preferredSampleRate)
        bitDepth = try c.decode(Int.self, forKey: .bitDepth, default: d.bitDepth)
        matchSourceSampleRate = try c.decode(Bool.self, forKey: .matchSourceSampleRate, default: d.matchSourceSampleRate)
        autoProfiles = try c.decode(Bool.self, forKey: .autoProfiles, default: d.autoProfiles)
        revertProfile = try c.decode(Bool.self, forKey: .revertProfile, default: d.revertProfile)
        notifyProfileChange = try c.decode(Bool.self, forKey: .notifyProfileChange, default: d.notifyProfileChange)
        noProfileBehavior = try c.decode(NoProfileBehavior.self, forKey: .noProfileBehavior, default: d.noProfileBehavior)
        bufferFrames = try c.decode(UInt32.self, forKey: .bufferFrames, default: d.bufferFrames)
        resamplingQuality = try c.decode(Int.self, forKey: .resamplingQuality, default: d.resamplingQuality)
        runInBackground = try c.decode(Bool.self, forKey: .runInBackground, default: d.runInBackground)
        autoUpdate = try c.decode(Bool.self, forKey: .autoUpdate, default: d.autoUpdate)
        betaUpdates = try c.decode(Bool.self, forKey: .betaUpdates, default: d.betaUpdates)
        lastUpdateCheck = try c.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
        hotkeys = try c.decode([HotkeyAction: Hotkey].self, forKey: .hotkeys, default: d.hotkeys)
        deviceHotkeyTargets = try c.decode([HotkeyAction: String].self, forKey: .deviceHotkeyTargets, default: [:])
        hiddenApps = try c.decode([String].self, forKey: .hiddenApps, default: [])
        showIdleApps = try c.decode(Bool.self, forKey: .showIdleApps, default: false)
    }
}

/// Everything Soundflow persists.
struct Config: Codable, Equatable, Sendable {
    var prefs = Preferences()
    var appRules: [String: AppRule] = [:]
    var devices: [String: DeviceSettings] = [:]
    var knownDevices: [String: KnownDevice] = [:]
    var multiOutputs: [MultiOutput] = []
    var profiles: [Profile] = Profile.defaults
    var activeProfileID: UUID?
    var history: [HistoryEvent] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prefs = try c.decode(Preferences.self, forKey: .prefs, default: Preferences())
        appRules = try c.decode([String: AppRule].self, forKey: .appRules, default: [:])
        devices = try c.decode([String: DeviceSettings].self, forKey: .devices, default: [:])
        knownDevices = try c.decode([String: KnownDevice].self, forKey: .knownDevices, default: [:])
        multiOutputs = try c.decode([MultiOutput].self, forKey: .multiOutputs, default: [])
        profiles = try c.decode([Profile].self, forKey: .profiles, default: Profile.defaults)
        activeProfileID = try c.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        history = try c.decode([HistoryEvent].self, forKey: .history, default: [])
    }

    func multiOutput(_ ref: OutputRef) -> MultiOutput? {
        guard let id = ref.multiOutputID else { return nil }
        return multiOutputs.first { $0.id == id }
    }

    func settings(for uid: String) -> DeviceSettings { devices[uid] ?? DeviceSettings() }
}

extension Profile {
    static var defaults: [Profile] {
        [
            Profile(name: "Работа", icon: "briefcase", hotkey: Hotkey(key: .one, modifiers: [.command])),
            Profile(name: "Игры", icon: "gamepad-2", hotkey: Hotkey(key: .two, modifiers: [.command])),
            Profile(name: "Стрим", icon: "radio", hotkey: Hotkey(key: .three, modifiers: [.command])),
            Profile(name: "Ночь", icon: "moon", hotkey: Hotkey(key: .four, modifiers: [.command]), maxVolume: 0.3,
                    triggers: [.schedule(weekdays: Set(1...7), start: 23 * 60, end: 7 * 60)], enabledTriggers: [0]),
        ]
    }
}

extension KeyedDecodingContainer {
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key, default value: T) throws -> T {
        (try? decodeIfPresent(type, forKey: key)) ?? value
    }
}
