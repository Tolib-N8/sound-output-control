import AppKit
import CryptoKit
import Foundation
import Observation

/// Semantic version ("1.2.3", "v1.2.3-beta.2"); pre-releases sort before the release.
struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    let numbers: [Int]
    let prerelease: String?

    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: "-", maxSplits: 1)
        guard let core = parts.first else { return nil }
        let numbers = core.split(separator: ".").map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        self.numbers = numbers.compactMap { $0 }
        prerelease = parts.count > 1 ? String(parts[1]) : nil
    }

    var description: String {
        numbers.map(String.init).joined(separator: ".") + (prerelease.map { "-\($0)" } ?? "")
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        let count = max(a.numbers.count, b.numbers.count)
        for i in 0..<count {
            let x = i < a.numbers.count ? a.numbers[i] : 0
            let y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y }
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil), (nil, _): return false
        case (_, nil): return true
        case let (x?, y?): return x.compare(y, options: .numeric) == .orderedAscending
        }
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// A release on GitHub that can be installed.
struct AvailableUpdate: Equatable, Sendable {
    var version: String
    var notes: String
    var dmgURL: URL
    var checksumURL: URL?
    var size: Int
    var pageURL: URL
    var isPrerelease: Bool
}

/// Subset of the GitHub release JSON.
struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let size: Int
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let htmlURL: URL
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case body, draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    /// The newest installable release (with a DMG) above `current`, honoring the beta channel.
    static func newest(in releases: [GitHubRelease], above current: AppVersion, includeBeta: Bool) -> AvailableUpdate? {
        releases
            .filter { !$0.draft && (includeBeta || !$0.prerelease) }
            .compactMap { release -> (AppVersion, AvailableUpdate)? in
                guard let version = AppVersion(release.tagName), version > current,
                      let dmg = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else { return nil }
                let checksum = release.assets.first { $0.name == dmg.name + ".sha256" }
                return (version, AvailableUpdate(version: version.description, notes: release.body ?? "", dmgURL: dmg.browserDownloadURL,
                                                 checksumURL: checksum?.browserDownloadURL, size: dmg.size, pageURL: release.htmlURL,
                                                 isPrerelease: release.prerelease))
            }
            .max { $0.0 < $1.0 }?.1
    }

    /// Extracts a SHA-256 written in the release notes (`SHA-256: <hex>`), used when no `.sha256` asset exists.
    static func checksum(inNotes notes: String) -> String? {
        let pattern = #"SHA-?256[^0-9a-fA-F]*([0-9a-fA-F]{64})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: notes, range: NSRange(notes.startIndex..., in: notes)),
              let range = Range(match.range(at: 1), in: notes) else { return nil }
        return notes[range].lowercased()
    }
}

/// Checks GitHub Releases, downloads and verifies the DMG, swaps the app bundle and relaunches.
@MainActor
@Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        case downloading(AvailableUpdate, progress: Double)
        case ready(AvailableUpdate)
        case installing
        case failed(String)
    }

    static let repository = "Tolib-N8/sound-output-control"

    private(set) var state: State = .idle
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var stagedApp: URL?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var work: Task<Void, Never>?

    var availableUpdate: AvailableUpdate? {
        switch state {
        case .available(let update), .downloading(let update, _), .ready(let update): update
        default: nil
        }
    }

    var currentVersion: AppVersion {
        #if DEBUG
        if let fake = UserDefaults.standard.string(forKey: "SFFakeVersion"), let version = AppVersion(fake) { return version }
        #endif
        return AppVersion(Bundle.main.shortVersion) ?? AppVersion("0.0.0")!
    }

    func start(model: AppModel) {
        self.model = model
        guard model.config.prefs.autoUpdate else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            MainActor.assumeIsolated { self?.check(userInitiated: false) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model?.config.prefs.autoUpdate == true else { return }
                self.check(userInitiated: false)
            }
        }
    }

    // MARK: - Check

    func check(userInitiated: Bool) {
        switch state {
        case .checking, .downloading, .installing, .ready: return
        default: break
        }
        state = .checking
        let includeBeta = model?.config.prefs.betaUpdates ?? false
        let current = currentVersion
        work = Task {
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases?per_page=20")!)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("Soundflow/\(Bundle.main.shortVersion)", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 20
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.message("GitHub недоступен") }
                let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
                model?.config.prefs.lastUpdateCheck = Date()
                if let update = GitHubRelease.newest(in: releases, above: current, includeBeta: includeBeta) {
                    state = .available(update)
                    if !userInitiated, model?.config.prefs.autoUpdate == true { download(update, automatic: true) }
                } else {
                    state = .upToDate
                }
            } catch {
                state = userInitiated ? .failed(Self.describe(error)) : .idle
            }
        }
    }

    // MARK: - Download & verify

    func download(_ update: AvailableUpdate, automatic: Bool = false) {
        state = .downloading(update, progress: 0)
        work = Task {
            do {
                let staged = try await prepare(update)
                stagedApp = staged
                state = .ready(update)
                if automatic {
                    NotificationService.post(title: "Обновление Soundflow \(update.version) готово",
                                             body: "Перезапустите приложение, чтобы установить. Иначе оно установится при выходе.")
                }
            } catch {
                state = .failed(Self.describe(error))
            }
        }
    }

    private func prepare(_ update: AvailableUpdate) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SoundflowUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dmg = folder.appendingPathComponent("Soundflow.dmg")

        // Expected checksum: a `.sha256` asset, or the hash quoted in the release notes.
        var expected = GitHubRelease.checksum(inNotes: update.notes)
        if let checksumURL = update.checksumURL {
            let (data, _) = try await URLSession.shared.data(from: checksumURL)
            expected = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? expected
        }
        guard let expected, expected.count == 64 else { throw UpdateError.message("В релизе нет контрольной суммы") }

        // Download with progress, then hash the file off the main thread.
        let downloaded = try await FileDownloader.download(update.dmgURL) { [weak self] progress in
            Task { @MainActor in
                guard let self, case .downloading = self.state else { return }
                self.state = .downloading(update, progress: min(progress, 0.99))
            }
        }
        try FileManager.default.moveItem(at: downloaded, to: dmg)
        let digest = try await Task.detached { try FileDownloader.sha256(of: dmg) }.value
        guard digest == expected else { throw UpdateError.message("Контрольная сумма не совпала — файл повреждён") }

        // Mount, copy the app out, verify it, unmount.
        let mount = folder.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try await Shell.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { Task.detached { try? await Shell.run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"]) } }
        guard let source = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw UpdateError.message("В образе нет приложения") }
        let staged = folder.appendingPathComponent(source.lastPathComponent)
        try await Shell.run("/usr/bin/ditto", ["--noextattr", source.path, staged.path])
        try await Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
        let bundle = Bundle(url: staged)
        guard bundle?.bundleIdentifier == Bundle.main.bundleIdentifier else { throw UpdateError.message("Неверный идентификатор приложения") }
        guard let version = (bundle?.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init),
              version == AppVersion(update.version) else { throw UpdateError.message("Версия в образе не совпадает с релизом") }
        return staged
    }

    // MARK: - Install

    /// Replaces the running app with the staged one and relaunches it.
    func installAndRelaunch() {
        guard case .ready = state, let stagedApp else { return }
        state = .installing
        do {
            let target = try install(stagedApp)
            Process.launchDetached("/bin/sh", ["-c", "sleep 1; /usr/bin/open \"$0\"", target.path])
            NSApp.terminate(nil)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    /// Called on quit: silently installs a ready update when automatic updates are on.
    func installOnQuitIfReady() {
        guard case .ready = state, let stagedApp, model?.config.prefs.autoUpdate == true else { return }
        _ = try? install(stagedApp)
    }

    private func install(_ staged: URL) throws -> URL {
        var target = Bundle.main.bundleURL
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "SFUpdateInstallPath") { target = URL(fileURLWithPath: path) }
        #endif
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            NSWorkspace.shared.activateFileViewerSelecting([staged])
            throw UpdateError.message("Нет прав на запись в «\(parent.lastPathComponent)». Перетащите новую версию вручную.")
        }
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: target)
        }
        stagedApp = nil
        return target
    }

    #if DEBUG
    /// Test hook: installs the staged update (to `-SFUpdateInstallPath`) without relaunching.
    func debugInstall() -> URL? {
        guard case .ready = state, let stagedApp else { return nil }
        return try? install(stagedApp)
    }
    #endif

    func dismissError() {
        if case .failed = state { state = .idle }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? UpdateError, case .message(let text) = error { return text }
        if (error as? URLError)?.code == .notConnectedToInternet { return "Нет подключения к интернету" }
        return error.localizedDescription
    }
}

enum UpdateError: Error { case message(String) }

/// URLSession download with progress reporting.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    private init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    /// Downloads `url` to a temporary file that the caller must move.
    static func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let downloader = FileDownloader(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            downloader.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        if expected > 0 { progress(Double(written) / Double(expected)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is deleted when this method returns, so keep a copy.
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError.message("Не удалось скачать обновление")
            }
            try FileManager.default.moveItem(at: location, to: keep)
            continuation?.resume(returning: keep)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.resume(throwing: error) }
        continuation = nil
    }
}

/// Runs a command-line tool off the main thread and throws on a non-zero exit status.
enum Shell {
    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw UpdateError.message("\((tool as NSString).lastPathComponent): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return output
        }.value
    }
}

extension Process {
    /// Starts a process that outlives the app (used to relaunch after an update).
    static func launchDetached(_ tool: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try? process.run()
    }
}
