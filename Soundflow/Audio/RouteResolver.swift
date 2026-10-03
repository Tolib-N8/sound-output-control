import Foundation

/// Where an app's audio actually goes right now.
struct ResolvedRoute: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case normal
        /// Every chosen device is gone; playing on a fallback device.
        case fallback(missing: [String])
        /// Some devices of a multi-output are gone.
        case partial(available: Int, total: Int)
        /// Paused until the missing device comes back.
        case waiting(missing: [String])
    }

    /// Hardware UIDs; the first is the clock device.
    var outputs: [String]
    var followsDefault: Bool
    var status: Status = .normal
    var multiOutputID: UUID?
    var extraLatencyMs: [String: Double] = [:]
    var driftCorrection = true

    var isFallback: Bool { if case .fallback = status { true } else { false } }
    var isWaiting: Bool { if case .waiting = status { true } else { false } }
}

struct DeviceLatencyInfo: Sendable {
    var uid: String
    var latencyMs: Double
}

enum RouteResolver {
    /// Expands output refs (devices and multi-outputs) into hardware UIDs, preserving order.
    static func expand(_ refs: [OutputRef], config: Config) -> (uids: [String], multi: MultiOutput?) {
        var uids: [String] = []
        var multi: MultiOutput?
        for ref in refs {
            if let output = config.multiOutput(ref) {
                multi = multi ?? output
                let ordered = output.clockUID.map { clock in [clock] + output.deviceUIDs.filter { $0 != clock } } ?? output.deviceUIDs
                for uid in ordered where !uids.contains(uid) { uids.append(uid) }
            } else if !ref.isMultiOutput, !uids.contains(ref) {
                uids.append(ref)
            }
        }
        return (uids, multi)
    }

    static func resolve(rule: AppRule, config: Config, connected: Set<String>, defaultUID: String?,
                        latencies: [String: Double] = [:], waiting: Bool = false) -> ResolvedRoute {
        let (wanted, multi) = expand(rule.outputs, config: config)
        guard !wanted.isEmpty else {
            return ResolvedRoute(outputs: defaultUID.map { [$0] } ?? [], followsDefault: true)
        }

        let available = wanted.filter(connected.contains)
        if available.isEmpty {
            let fallback = fallbackDevice(rule: rule, excluding: Set(wanted), config: config, connected: connected, defaultUID: defaultUID)
            // While waiting, the app is still captured (silenced) through the fallback device.
            return ResolvedRoute(outputs: fallback.map { [$0] } ?? [], followsDefault: false,
                                 status: waiting || !rule.useFallback ? .waiting(missing: wanted) : .fallback(missing: wanted))
        }

        var route = ResolvedRoute(outputs: available, followsDefault: false, multiOutputID: multi?.id)
        if available.count < wanted.count { route.status = .partial(available: available.count, total: wanted.count) }
        if let multi {
            route.driftCorrection = multi.driftCorrection
            route.extraLatencyMs = alignment(for: multi, outputs: available, latencies: latencies)
        }
        return route
    }

    /// Extra delay per device so every output of a multi-output plays in sync.
    static func alignment(for multi: MultiOutput, outputs: [String], latencies: [String: Double]) -> [String: Double] {
        var result: [String: Double] = [:]
        let slowest = multi.alignLatency ? outputs.map { latencies[$0] ?? 0 }.max() ?? 0 : 0
        for uid in outputs {
            let auto = multi.alignLatency ? slowest - (latencies[uid] ?? 0) : 0
            let total = auto + (multi.delays[uid] ?? 0)
            if total > 0.5 { result[uid] = total }
        }
        return result
    }

    /// The device to use when all of an app's devices are disconnected.
    static func fallbackDevice(rule: AppRule, excluding: Set<String>, config: Config, connected: Set<String>, defaultUID: String?) -> String? {
        if let explicit = rule.fallbackUID, connected.contains(explicit), !excluding.contains(explicit) { return explicit }
        for uid in excluding {
            if let deviceFallback = config.settings(for: uid).fallbackUID, connected.contains(deviceFallback), !excluding.contains(deviceFallback) {
                return deviceFallback
            }
        }
        if let ranked = config.prefs.devicePriority.first(where: { connected.contains($0) && !excluding.contains($0) }) { return ranked }
        if let defaultUID, connected.contains(defaultUID), !excluding.contains(defaultUID) { return defaultUID }
        return connected.sorted().first { !excluding.contains($0) }
    }

    /// Whether the app has to be captured; untouched apps keep playing natively with zero overhead.
    static func needsTap(rule: AppRule, route: ResolvedRoute, defaultUID: String?, gainFactor: Double, normalize: Bool) -> Bool {
        if route.isWaiting { return true }
        if rule.muted || abs(rule.volume - 1) > 0.001 || abs(rule.balance) > 0.001 { return true }
        if abs(gainFactor - 1) > 0.001 || normalize { return true }
        if route.followsDefault { return false }
        return route.outputs != (defaultUID.map { [$0] } ?? [])
    }
}
