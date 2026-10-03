import CoreAudio
import Foundation
import Observation

/// Owns the app routers on a background queue (creating aggregates can take ~100 ms).
final class RouterHost: @unchecked Sendable {
    private let queue = DispatchQueue(label: "soundflow.engine", qos: .userInitiated)
    private var routers: [String: AppRouter] = [:]

    struct Outcome: Sendable {
        var latencyMs: [String: Double] = [:]
        var errors: [String: String] = [:]
    }

    func apply(_ desired: [String: (RouteConfig, RenderState)], completion: @escaping @Sendable (Outcome) -> Void) {
        queue.async { [self] in
            var outcome = Outcome()
            for (bundleID, router) in routers where desired[bundleID] == nil {
                router.stop()
                routers[bundleID] = nil
            }
            for (bundleID, (config, state)) in desired {
                do {
                    if let router = routers[bundleID] {
                        try router.update(config)
                        outcome.latencyMs[bundleID] = router.latencyMs
                    } else {
                        let router = try AppRouter(config: config, state: state)
                        routers[bundleID] = router
                        outcome.latencyMs[bundleID] = router.latencyMs
                    }
                } catch {
                    routers[bundleID]?.stop()
                    routers[bundleID] = nil
                    outcome.errors[bundleID] = "\(error)"
                    audioLog.error("Router \(bundleID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
            completion(outcome)
        }
    }

    func stopAll(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            routers.values.forEach { $0.stop() }
            routers.removeAll()
            completion?()
        }
    }

    func stopAllSync() {
        queue.sync {
            routers.values.forEach { $0.stop() }
            routers.removeAll()
        }
    }
}

/// Turns rules + live devices/processes into running routers and exposes their status.
@MainActor
@Observable
final class AudioEngine {
    enum Health: Equatable {
        case running, permissionNeeded, error(String), restarting
    }

    struct AppStatus: Equatable {
        var route: ResolvedRoute
        var tapped: Bool
        var error: String?
    }

    struct Stats: Equatable {
        var latencyMs: Double = 0
        var cpuPercent: Double = 0
        var streams = 0
        var failures = 0
        var startedAt = Date()
    }

    struct Input {
        var apps: [AudioApp]
        var config: Config
        var devices: [AudioDevice]
        var defaultUID: String?
        var ducked: Set<String>
        var waiting: Set<String>
        var volumeCap: Double?
    }

    private(set) var statuses: [String: AppStatus] = [:]
    private(set) var health: Health = .running
    private(set) var stats = Stats()
    private(set) var permission: AudioCapturePermission = PermissionService.audioCapture
    var enabled = true

    @ObservationIgnored private let host = RouterHost()
    @ObservationIgnored private var states: [String: RenderState] = [:]
    @ObservationIgnored private var lastConfigs: [String: RouteConfig] = [:]
    @ObservationIgnored private var lastInput: Input?
    @ObservationIgnored private(set) var levels: [String: Float] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var latencies: [String: Double] = [:]

    init() {
        audioLog.info("Audio capture permission at launch: \(String(describing: self.permission), privacy: .public)")
        timers.append(Timer.scheduledTimer(withTimeInterval: 1 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleLevels() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleStats() }
        })
    }

    func level(_ bundleID: String) -> Float { levels[bundleID] ?? 0 }

    @ObservationIgnored private var permissionCheckTick = 0

    func refreshPermission(force: Bool = false) {
        // Preflight is an IPC to tccd: poll rarely, and not at all once granted.
        permissionCheckTick += 1
        guard force || (permission != .authorized && permissionCheckTick % 5 == 0) else { return }
        let fresh = PermissionService.audioCapture
        if fresh != permission {
            audioLog.info("Audio capture permission: \(String(describing: fresh), privacy: .public)")
            permission = fresh
            if let lastInput { reconcile(lastInput) }
        }
    }

    // MARK: - Reconciliation

    func reconcile(_ input: Input) {
        lastInput = input
        let connected = Set(input.devices.map(\.uid))
        let deviceLatency = Dictionary(input.devices.map { ($0.uid, $0.latencyMs) }, uniquingKeysWith: { a, _ in a })
        let rates = Dictionary(input.devices.map { ($0.uid, $0.sampleRate) }, uniquingKeysWith: { a, _ in a })
        let prefs = input.config.prefs
        let canTap = enabled && permission != .denied

        var newStatuses: [String: AppStatus] = [:]
        var desired: [String: (RouteConfig, RenderState)] = [:]

        for app in input.apps {
            let rule = input.config.appRules[app.bundleID] ?? AppRule(volume: prefs.newAppVolume, outputs: prefs.newAppOutput.map { [$0] } ?? [])
            let waiting = input.waiting.contains(app.bundleID)
            let route = RouteResolver.resolve(rule: rule, config: input.config, connected: connected, defaultUID: input.defaultUID,
                                              latencies: deviceLatency, waiting: waiting)
            let duck = input.ducked.contains(app.bundleID) ? 1 - prefs.duckAmount : 1
            let tap = canTap && !route.outputs.isEmpty
                && RouteResolver.needsTap(rule: rule, route: route, defaultUID: input.defaultUID, gainFactor: duck, normalize: prefs.normalize)

            let state = states[app.bundleID] ?? RenderState()
            states[app.bundleID] = state
            var volume = rule.volume
            if let cap = input.volumeCap { volume = min(volume, cap) }
            state.targetGain = Float(rule.muted || waiting ? 0 : volume * duck)
            state.balance = Float(rule.balance)
            state.normalize = prefs.normalize

            newStatuses[app.bundleID] = AppStatus(route: route, tapped: tap, error: statuses[app.bundleID]?.error)
            guard tap else { continue }
            let clockRate = rates[route.outputs[0]] ?? 48000
            let extra = route.extraLatencyMs.mapValues { UInt32(($0 / 1000 * clockRate).rounded()) }
            let config = RouteConfig(bundleID: app.bundleID, processObjects: app.processObjects, outputUIDs: route.outputs,
                                     driftCompensation: route.driftCorrection, extraLatency: extra, bufferFrames: prefs.bufferFrames,
                                     resamplingQuality: prefs.resamplingQuality)
            desired[app.bundleID] = (config, state)
        }

        statuses = newStatuses
        if permission == .denied { health = .permissionNeeded } else if health == .permissionNeeded { health = .running }
        let configs = desired.mapValues(\.0)
        guard configs != lastConfigs else { return }
        lastConfigs = configs
        states = states.filter { newStatuses[$0.key] != nil }

        generation += 1
        let current = generation
        host.apply(desired) { [weak self] outcome in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(outcome, generation: current) }
            }
        }
    }

    private func finish(_ outcome: RouterHost.Outcome, generation: Int) {
        guard generation == self.generation else { return }
        latencies = outcome.latencyMs
        for (bundleID, status) in statuses {
            let error = outcome.errors[bundleID]
            if status.error != error { statuses[bundleID]?.error = error }
        }
        if !outcome.errors.isEmpty {
            stats.failures += outcome.errors.count
            // Forget failed configs so the next reconcile retries them.
            for bundleID in outcome.errors.keys { lastConfigs[bundleID] = nil }
            if outcome.latencyMs.isEmpty {
                health = .error(outcome.errors.values.first ?? "")
                scheduleRetry()
                return
            }
        }
        health = permission == .denied ? .permissionNeeded : .running
    }

    private func scheduleRetry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, case .error = self.health, let input = self.lastInput else { return }
                self.health = .restarting
                self.reconcile(input)
            }
        }
    }

    /// Tears every router down and rebuilds from the last input.
    func restart() {
        health = .restarting
        lastConfigs = [:]
        host.stopAll { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.stats = Stats(failures: self.stats.failures)
                    if let input = self.lastInput { self.reconcile(input) }
                    if self.health == .restarting { self.health = .running }
                }
            }
        }
    }

    func shutdown() {
        host.stopAllSync()
        lastConfigs = [:]
    }

    // MARK: - Metering

    private func sampleLevels() {
        for (bundleID, state) in states {
            let peak = state.peak
            levels[bundleID] = max(peak.left, peak.right)
            state.decayPeaks()
        }
    }

    private func sampleStats() {
        let active = statuses.filter(\.value.tapped)
        let load = active.keys.compactMap { states[$0]?.takeLoad() }.reduce(0, +)
        let latency = latencies.values.max() ?? (lastInput?.devices.first { $0.uid == lastInput?.defaultUID }?.latencyMs ?? 0)
        let fresh = Stats(latencyMs: latency, cpuPercent: load * 100, streams: active.count, failures: stats.failures, startedAt: stats.startedAt)
        if abs(fresh.cpuPercent - stats.cpuPercent) > 0.2 || fresh.streams != stats.streams || abs(fresh.latencyMs - stats.latencyMs) > 0.05 {
            stats = fresh
        }
        refreshPermission()
    }
}
