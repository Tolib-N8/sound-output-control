import Foundation
import Observation

/// Loads and persists `Config` as JSON in Application Support, saving changes with a short debounce.
@MainActor
@Observable
final class ConfigStore {
    var config: Config {
        didSet { if config != oldValue { scheduleSave() } }
    }

    @ObservationIgnored private let url: URL
    @ObservationIgnored private var saveWork: DispatchWorkItem?

    init(url: URL = ConfigStore.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url) {
            do {
                config = try JSONDecoder.soundflow.decode(Config.self, from: data)
            } catch {
                audioLog.error("Config unreadable, starting fresh: \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("broken"))
                config = Config()
            }
        } else {
            config = Config()
        }
    }

    nonisolated static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Soundflow", isDirectory: true).appendingPathComponent("config.json")
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.soundflow.encode(config)
            try data.write(to: url, options: .atomic)
        } catch {
            audioLog.error("Config save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

extension JSONEncoder {
    static var soundflow: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var soundflow: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
