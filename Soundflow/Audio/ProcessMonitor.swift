import AppKit
import CoreAudio
import Observation

/// An application that owns one or more Core Audio client processes.
struct AudioApp: Identifiable, Hashable, Sendable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let pid: pid_t
    var processObjects: [AudioObjectID]
    var isPlaying: Bool
    var isUsingInput: Bool
    var isHidden: Bool
}

/// Watches `kAudioHardwarePropertyProcessObjectList` and groups audio processes by their responsible app.
@MainActor
@Observable
final class ProcessMonitor {
    private(set) var apps: [AudioApp] = []

    @ObservationIgnored var onChange: (() -> Void)?
    /// Fired when an app starts producing sound for the first time in this session.
    @ObservationIgnored var onAppStartedPlaying: ((AudioApp) -> Void)?

    @ObservationIgnored private var listListener: PropertyListener?
    @ObservationIgnored private var processListeners: [AudioObjectID: [PropertyListener]] = [:]
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var seenPlaying: Set<String> = []
    @ObservationIgnored private var scheduled = false
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    static let hiddenSystemApps: Set<String> = [
        "com.apple.controlcenter", "com.apple.Siri", "com.apple.siri", "com.apple.PowerChime", "com.apple.notificationcenterui",
        "com.apple.loginwindow", "com.apple.dock", "com.apple.systemuiserver", "com.apple.TextInputMenuAgent",
        "com.apple.universalaccessd", "com.apple.accessibility.heard", "com.apple.CoreSpeech",
    ]

    init() {
        reload()
        listListener = PropertyListener(CA.system, .init(kAudioHardwarePropertyProcessObjectList)) { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleReload() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func app(_ bundleID: String) -> AudioApp? { apps.first { $0.bundleID == bundleID } }

    /// Whether the app has produced sound at any point since Soundflow started.
    func hasPlayed(_ bundleID: String) -> Bool { seenPlaying.contains(bundleID) }

    private func scheduleReload() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduled = false
                self?.reload()
            }
        }
    }

    func reload() {
        let objects = (try? CA.getArray(CA.system, .init(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self)) ?? []
        var grouped: [String: AudioApp] = [:]
        var order: [String] = []

        for object in objects {
            let pid: pid_t = (try? CA.get(object, .init(kAudioProcessPropertyPID), default: pid_t(-1))) ?? -1
            guard pid > 0, pid != ownPID else { continue }
            let owner = Responsibility.responsiblePID(for: pid)
            guard owner != ownPID,
                  let running = NSRunningApplication(processIdentifier: owner) ?? NSRunningApplication(processIdentifier: pid),
                  running.activationPolicy != .prohibited,
                  let bundleID = running.bundleIdentifier else { continue }

            let output = ((try? CA.get(object, .init(kAudioProcessPropertyIsRunningOutput), default: UInt32(0))) ?? 0) != 0
            let input = ((try? CA.get(object, .init(kAudioProcessPropertyIsRunningInput), default: UInt32(0))) ?? 0) != 0
            // Menu-bar agents and system services only show up while they actually make sound.
            if running.activationPolicy != .regular, !output { continue }
            if Self.hiddenSystemApps.contains(bundleID), !output { continue }

            if var existing = grouped[bundleID] {
                existing.processObjects.append(object)
                existing.isPlaying = existing.isPlaying || output
                existing.isUsingInput = existing.isUsingInput || input
                grouped[bundleID] = existing
            } else {
                order.append(bundleID)
                grouped[bundleID] = AudioApp(
                    bundleID: bundleID,
                    name: running.localizedName ?? bundleID,
                    pid: running.processIdentifier,
                    processObjects: [object],
                    isPlaying: output,
                    isUsingInput: input,
                    isHidden: running.isHidden
                )
            }
        }

        let fresh = order.compactMap { grouped[$0] }.map { app in
            var app = app
            app.processObjects.sort()
            return app
        }.sorted { a, b in
            if a.isPlaying != b.isPlaying { return a.isPlaying }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        installListeners(objects)
        for app in fresh where app.isPlaying && !seenPlaying.contains(app.bundleID) {
            seenPlaying.insert(app.bundleID)
            onAppStartedPlaying?(app)
        }
        if fresh != apps {
            audioLog.debug("Audio apps: \(fresh.map { "\($0.bundleID)\($0.isPlaying ? "▶" : "")" }.joined(separator: ", "), privacy: .public)")
            apps = fresh
            onChange?()
        }
    }

    private func installListeners(_ objects: [AudioObjectID]) {
        let current = Set(objects)
        processListeners = processListeners.filter { current.contains($0.key) }
        for object in objects where processListeners[object] == nil {
            let handler: @Sendable () -> Void = { [weak self] in
                MainActor.assumeIsolated { self?.scheduleReload() }
            }
            processListeners[object] = [
                PropertyListener(object, .init(kAudioProcessPropertyIsRunningOutput), handler: handler),
                PropertyListener(object, .init(kAudioProcessPropertyIsRunningInput), handler: handler),
            ]
        }
    }
}

/// Resolves helper processes (WebKit content, Chrome renderers…) to the app responsible for them.
enum Responsibility {
    private typealias Fn = @convention(c) (pid_t) -> pid_t
    private static let fn: Fn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: Fn.self)
    }()

    static func responsiblePID(for pid: pid_t) -> pid_t {
        guard let fn else { return pid }
        let owner = fn(pid)
        return owner > 0 ? owner : pid
    }
}

/// Caches app icons and names by bundle identifier, including apps that are not running.
@MainActor
enum AppInfo {
    private static var icons: [String: NSImage] = [:]
    private static var names: [String: String] = [:]

    static func icon(_ bundleID: String) -> NSImage {
        if let cached = icons[bundleID] { return cached }
        let image: NSImage
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first, let icon = running.icon {
            image = icon
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSWorkspace.shared.icon(for: .application)
        }
        icons[bundleID] = image
        return image
    }

    static func name(_ bundleID: String) -> String {
        if let cached = names[bundleID] { return cached }
        var name = bundleID
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first, let localized = running.localizedName {
            name = localized
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        names[bundleID] = name
        return name
    }

    static func remember(_ app: AudioApp) {
        names[app.bundleID] = app.name
    }
}
