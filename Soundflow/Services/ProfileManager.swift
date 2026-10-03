import AppKit
import CoreWLAN

struct TriggerContext {
    var connectedDevices: Set<String>
    var runningApps: Set<String>
    var ssid: String?
    var date: Date
    var calendar = Calendar(identifier: .gregorian)

    /// 1 = Monday … 7 = Sunday.
    var weekday: Int { (calendar.component(.weekday, from: date) + 5) % 7 + 1 }
    var minutes: Int { calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date) }
}

/// Applies profiles (manually or by their automatic conditions) and restores the previous state.
@MainActor
final class ProfileManager {
    private unowned let model: AppModel
    private var snapshot: (rules: [String: AppRule], defaultUID: String?)?
    private var autoActivated: UUID?
    private var timer: Timer?

    init(model: AppModel) { self.model = model }

    func start() {
        evaluate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
    }

    // MARK: - Activation

    func toggle(_ id: UUID) {
        if model.config.activeProfileID == id { deactivate() } else { activate(id) }
    }

    func activate(_ id: UUID, automatic: Bool = false) {
        guard let profile = model.config.profiles.first(where: { $0.id == id }) else { return }
        if model.config.activeProfileID != nil { restoreSnapshot() }
        snapshot = (model.config.appRules, model.devices.defaultOutputUID)
        autoActivated = automatic ? id : nil

        var rules = model.config.appRules
        let explicit = Set(profile.rules.map(\.bundleID))
        let others = Set(rules.keys).union(model.apps.map(\.bundleID)).subtracting(explicit)
        // "Остальные приложения" with default values means "leave them alone".
        let touchesOthers = abs(profile.othersVolume - 1) > 0.001 || profile.othersOutput != nil
        for bundleID in others where touchesOthers {
            var rule = rules[bundleID] ?? AppRule()
            rule.volume = profile.othersVolume
            rule.outputs = profile.othersOutput.map { [$0] } ?? []
            rule.muted = false
            rules[bundleID] = rule
        }
        for appRule in profile.rules {
            var rule = rules[appRule.bundleID] ?? AppRule()
            rule.volume = appRule.volume
            rule.muted = appRule.muted
            rule.outputs = appRule.output.map { [$0] } ?? []
            rules[appRule.bundleID] = rule
        }
        model.config.appRules = rules
        model.config.activeProfileID = id
        if let main = profile.mainOutput, !main.isMultiOutput, model.devices.isConnected(main) {
            model.devices.setDefault(main)
        }
        model.reconcile()
        if model.config.prefs.notifyProfileChange {
            NotificationService.post(title: "Профиль «\(profile.name)»", body: automatic ? "Включён автоматически" : "Включён")
        }
    }

    func deactivate() {
        guard model.config.activeProfileID != nil else { return }
        if model.config.prefs.noProfileBehavior == .defaults {
            model.config.appRules = [:]
            snapshot = nil
        } else {
            restoreSnapshot()
        }
        model.config.activeProfileID = nil
        autoActivated = nil
        model.reconcile()
    }

    private func restoreSnapshot() {
        guard let snapshot else { return }
        model.config.appRules = snapshot.rules
        if let uid = snapshot.defaultUID, model.devices.isConnected(uid) { model.devices.setDefault(uid) }
        self.snapshot = nil
    }

    // MARK: - Automatic switching

    func evaluate() {
        guard model.config.prefs.autoProfiles else { return }
        let context = TriggerContext(
            connectedDevices: Set(model.devices.devices.map(\.uid)),
            runningApps: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)),
            ssid: CWWiFiClient.shared().interface()?.ssid(),
            date: Date()
        )
        let matching = model.config.profiles.first { profile in
            !profile.activeTriggers.isEmpty && profile.activeTriggers.allSatisfy { Self.matches($0, context) }
        }
        if let matching {
            if model.config.activeProfileID != matching.id, autoActivated != nil || model.config.activeProfileID == nil {
                activate(matching.id, automatic: true)
            }
        } else if let auto = autoActivated, model.config.activeProfileID == auto, model.config.prefs.revertProfile {
            deactivate()
        }
    }

    nonisolated static func matches(_ trigger: ProfileTrigger, _ context: TriggerContext) -> Bool {
        switch trigger {
        case let .deviceConnected(uid):
            return context.connectedDevices.contains(uid)
        case let .appRunning(bundleID):
            return context.runningApps.contains(bundleID)
        case let .wifi(ssid):
            return context.ssid == ssid
        case let .schedule(weekdays, start, end):
            let now = context.minutes
            if start <= end {
                return weekdays.contains(context.weekday) && now >= start && now < end
            }
            // Overnight range (e.g. 23:00–7:00): the evening part belongs to today, the morning part to yesterday.
            if now >= start { return weekdays.contains(context.weekday) }
            let yesterday = context.weekday == 1 ? 7 : context.weekday - 1
            return now < end && weekdays.contains(yesterday)
        }
    }
}

extension ProfileTrigger {
    var title: String {
        switch self {
        case .deviceConnected: "Подключено устройство"
        case .appRunning: "Запущено приложение"
        case .wifi(let ssid): "Сеть «\(ssid)»"
        case .schedule: "Расписание"
        }
    }

    var icon: String {
        switch self {
        case .deviceConnected: "headphones"
        case .appRunning: "app-window"
        case .wifi: "wifi"
        case .schedule: "clock-3"
        }
    }

    static func scheduleText(weekdays: Set<Int>, start: Int, end: Int) -> String {
        let days: String
        if weekdays == Set(1...5) { days = "Будни" }
        else if weekdays == Set(1...7) { days = "Каждый день" }
        else if weekdays == [6, 7] { days = "Выходные" }
        else {
            let names = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]
            days = weekdays.sorted().map { names[$0 - 1] }.joined(separator: ", ")
        }
        func time(_ minutes: Int) -> String { String(format: "%d:%02d", minutes / 60, minutes % 60) }
        return "\(days) \(time(start))–\(time(end))"
    }
}
