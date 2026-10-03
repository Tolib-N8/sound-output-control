import Foundation

/// Russian plural form: plural(5, "приложение", "приложения", "приложений") → "приложений".
func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let mod10 = n % 10, mod100 = n % 100
    if mod10 == 1 && mod100 != 11 { return one }
    if (2...4).contains(mod10) && !(12...14).contains(mod100) { return few }
    return many
}

func countText(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    "\(n) \(plural(n, one, few, many))"
}

func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))" }

func milliseconds(_ ms: Double) -> String {
    ms < 10 ? String(format: "%.1f мс", ms) : "\(Int(ms.rounded())) мс"
}

extension AppModel {
    /// Status line under the app's name.
    func statusText(_ app: AudioApp) -> (text: String, tone: StatusTone) {
        let rule = rule(app.bundleID)
        if let route = status(app.bundleID)?.route, case let .waiting(missing) = route.status {
            return ("Пауза — ждёт \(name(of: missing.first ?? ""))", .warning)
        }
        if rule.muted { return ("Звук выключен", .muted) }
        if let route = status(app.bundleID)?.route, case let .partial(available, total) = route.status {
            return ("\(available) из \(total) устройств доступно", .warning)
        }
        if app.isUsingInput && Self.callApps.contains(app.bundleID) { return ("Звонок", .playing) }
        if app.isPlaying { return (app.isHidden ? "В фоне" : "Играет", .playing) }
        return ("Тишина", .idle)
    }
}

enum StatusTone { case playing, idle, muted, warning }
