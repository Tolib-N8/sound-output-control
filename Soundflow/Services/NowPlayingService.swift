import AppKit
import Observation

/// What the system reports as "Now Playing" (any app: Spotify, Music, browsers…).
struct NowPlaying: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    var duration: Double?
    /// Elapsed seconds at `timestamp`.
    var elapsed: Double
    var rate: Double
    var timestamp: Date
    var isPlaying: Bool
    var pid: pid_t
    var bundleID: String?
    var artworkID: String?

    /// Playback position now, extrapolated from the last report.
    func position(at now: Date = Date()) -> Double {
        let moved = isPlaying ? now.timeIntervalSince(timestamp) * max(rate, 0) : 0
        let value = max(0, elapsed + moved)
        return duration.map { min(value, $0) } ?? value
    }

    var subtitle: String {
        [artist, album].filter { !$0.isEmpty }.joined(separator: " — ")
    }

    /// Builds the state from one helper event; nil when nothing is playing.
    static func parse(_ event: [String: Any], now: Date = Date()) -> NowPlaying? {
        let title = (event["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let pid = (event["pid"] as? NSNumber)?.int32Value ?? 0
        guard !title.isEmpty || pid > 0 else { return nil }
        let timestamp = (event["timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? now
        let duration = (event["duration"] as? NSNumber)?.doubleValue
        return NowPlaying(
            title: title,
            artist: event["artist"] as? String ?? "",
            album: event["album"] as? String ?? "",
            duration: duration.flatMap { $0 > 0 && $0.isFinite ? $0 : nil },
            elapsed: (event["elapsed"] as? NSNumber)?.doubleValue ?? 0,
            rate: (event["rate"] as? NSNumber)?.doubleValue ?? ((event["playing"] as? NSNumber)?.boolValue == true ? 1 : 0),
            timestamp: timestamp,
            isPlaying: (event["playing"] as? NSNumber)?.boolValue ?? false,
            pid: pid,
            bundleID: nil,
            artworkID: event["artworkId"] as? String
        )
    }
}

/// Runs the MediaRemote bridge (`/usr/bin/perl nowplaying.pl SoundflowNowPlaying.dylib`) and
/// publishes the now-playing state. Commands go to the helper's stdin.
@MainActor
@Observable
final class NowPlayingService {
    enum Availability: Equatable { case starting, available, unavailable(String) }

    private(set) var current: NowPlaying?
    private(set) var artwork: NSImage?
    private(set) var palette = ArtworkPalette.default
    private(set) var availability: Availability = .starting

    /// Called when the source app changes (drives the spectrum visualizer).
    @ObservationIgnored var onSourceChange: ((String?) -> Void)?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var pending = Data()
    @ObservationIgnored private var restartDelay: Double = 1
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var stopped = false

    func start() {
        guard process == nil, !stopped else { return }
        guard let script = Bundle.main.url(forResource: "nowplaying", withExtension: "pl"),
              let library = Bundle.main.url(forResource: "SoundflowNowPlaying", withExtension: "dylib") else {
            availability = .unavailable("Компонент плеера не найден в приложении")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, library.path]
        let stdout = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data) }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.helperExited(status: status) }
        }
        do {
            try process.run()
            self.process = process
            input = stdin.fileHandleForWriting
            startedAt = Date()
        } catch {
            availability = .unavailable("Не удалось запустить компонент плеера")
        }
    }

    func stop() {
        stopped = true
        try? input?.close()
        process?.terminate()
        process = nil
    }

    // MARK: - Commands

    func togglePlayPause() {
        send("toggle")
        // Optimistic: flip immediately, the helper confirms a moment later.
        if var state = current {
            state.elapsed = state.position()
            state.timestamp = Date()
            state.isPlaying.toggle()
            current = state
        }
    }

    func next() { send("next") }
    func previous() { send("previous") }

    func seek(to seconds: Double) {
        send("seek \(max(0, seconds))")
        if var state = current {
            state.elapsed = seconds
            state.timestamp = Date()
            current = state
        }
    }

    private func send(_ command: String) {
        guard let input else { return }
        try? input.write(contentsOf: Data((command + "\n").utf8))
    }

    // MARK: - Helper output

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(object)
        }
    }

    private func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "ready":
            availability = .available
            restartDelay = 1
        case "error":
            availability = .unavailable(event["message"] as? String ?? "MediaRemote недоступен")
        case "state":
            var state = NowPlaying.parse(event)
            if let pid = state?.pid, pid > 0 {
                let owner = Responsibility.responsiblePID(for: pid)
                state?.bundleID = (NSRunningApplication(processIdentifier: owner) ?? NSRunningApplication(processIdentifier: pid))?.bundleIdentifier
            }
            if let base64 = event["artwork"] as? String, let data = Data(base64Encoded: base64), let image = NSImage(data: data) {
                artwork = image
                palette = ArtworkPalette.extract(from: image)
            } else if state?.artworkID == nil {
                artwork = nil
                palette = .default
            }
            if state != current {
                let sourceChanged = state?.bundleID != current?.bundleID
                if state?.title != current?.title {
                    audioLog.info("Now playing: \(state?.title ?? "—", privacy: .public) [\(state?.bundleID ?? "?", privacy: .public)]")
                }
                current = state
                if sourceChanged { onSourceChange?(state?.bundleID) }
            }
        default:
            break
        }
    }

    private func helperExited(status: Int32) {
        process = nil
        input = nil
        guard !stopped else { return }
        // Exiting right away means the bridge can't work on this macOS; otherwise restart with backoff.
        if status == 2 || Date().timeIntervalSince(startedAt) < 2 && restartDelay >= 8 {
            availability = .unavailable("macOS не отдаёт данные «Сейчас играет»")
        }
        let delay = restartDelay
        restartDelay = min(30, restartDelay * 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.start() }
        }
    }
}
