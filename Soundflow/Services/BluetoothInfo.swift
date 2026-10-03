import Foundation
import IOBluetooth
import Observation

/// Battery levels of connected Bluetooth audio devices, read from `system_profiler` when macOS exposes them.
@MainActor
@Observable
final class BluetoothInfo {
    struct Battery: Equatable, Sendable {
        var left: Int?
        var right: Int?
        var caseLevel: Int?
        var main: Int?

        var summary: Int? {
            if let main { return main }
            let buds = [left, right].compactMap { $0 }
            return buds.isEmpty ? nil : buds.min()
        }
    }

    private(set) var batteries: [String: Battery] = [:]
    @ObservationIgnored private var addresses: [String: String] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var warned: Set<String> = []
    @ObservationIgnored private weak var model: AppModel?

    func start(model: AppModel) {
        self.model = model
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func battery(for name: String) -> Battery? { batteries[name] }
    func level(for name: String) -> Int? { batteries[name]?.summary }

    func refresh() {
        Task.detached(priority: .utility) {
            let (result, addresses) = Self.read()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.addresses = addresses
                if result != self.batteries { self.batteries = result }
                self.checkLow()
            }
        }
    }

    /// Closes the Bluetooth connection to a device (matched by name).
    func disconnect(name: String) {
        guard let address = addresses[name] else { return }
        IOBluetoothDevice(addressString: address)?.closeConnection()
    }

    private func checkLow() {
        guard let model, model.config.prefs.warnLowBattery else { return }
        for (name, battery) in batteries {
            guard let level = battery.summary else { continue }
            if level < 15, !warned.contains(name) {
                warned.insert(name)
                NotificationService.post(title: "Низкий заряд: \(name)", body: "Осталось \(level)%")
            } else if level >= 20 {
                warned.remove(name)
            }
        }
    }

    nonisolated private static func read() -> ([String: Battery], [String: String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return ([:], [:]) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = json["SPBluetoothDataType"] as? [[String: Any]] else { return ([:], [:]) }
        var result: [String: Battery] = [:]
        var addresses: [String: String] = [:]
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    if let address = info["device_address"] as? String { addresses[name] = address }
                    func percent(_ key: String) -> Int? {
                        (info[key] as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "")) }
                    }
                    let battery = Battery(left: percent("device_batteryLevelLeft"), right: percent("device_batteryLevelRight"),
                                          caseLevel: percent("device_batteryLevelCase"), main: percent("device_batteryLevelMain"))
                    if battery.summary != nil || battery.caseLevel != nil { result[name] = battery }
                }
            }
        }
        return (result, addresses)
    }
}
