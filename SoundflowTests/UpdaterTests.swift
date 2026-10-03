import CoreAudio
import XCTest
@testable import Soundflow

final class UpdaterTests: XCTestCase {
    func testVersionOrdering() {
        let v = { AppVersion($0)! }
        XCTAssertLessThan(v("1.0.0"), v("1.0.1"))
        XCTAssertLessThan(v("1.9.0"), v("1.10.0"))
        XCTAssertLessThan(v("1.1.0-beta.2"), v("1.1.0"))
        XCTAssertLessThan(v("1.1.0-beta.2"), v("1.1.0-beta.10"))
        XCTAssertEqual(v("v1.2"), v("1.2.0"))
        XCTAssertNil(AppVersion("latest"))
    }

    private func release(_ tag: String, prerelease: Bool = false, draft: Bool = false, dmg: Bool = true) -> GitHubRelease {
        var assets = ""
        if dmg {
            assets = """
            {"name":"Soundflow-\(tag).dmg","size":100,"browser_download_url":"https://example.com/\(tag).dmg"},
            {"name":"Soundflow-\(tag).dmg.sha256","size":90,"browser_download_url":"https://example.com/\(tag).sha"}
            """
        }
        let json = """
        {"tag_name":"\(tag)","body":"notes","draft":\(draft),"prerelease":\(prerelease),
         "html_url":"https://example.com/\(tag)","assets":[\(assets)]}
        """
        return try! JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
    }

    func testPicksNewestStableRelease() {
        let releases = [release("v1.0.0"), release("v1.2.0"), release("v1.3.0-beta.1", prerelease: true),
                        release("v1.4.0", draft: true), release("v1.5.0", dmg: false)]
        let stable = GitHubRelease.newest(in: releases, above: AppVersion("1.0.0")!, includeBeta: false)
        XCTAssertEqual(stable?.version, "1.2.0")
        XCTAssertEqual(stable?.checksumURL, URL(string: "https://example.com/v1.2.0.sha"))
        let beta = GitHubRelease.newest(in: releases, above: AppVersion("1.0.0")!, includeBeta: true)
        XCTAssertEqual(beta?.version, "1.3.0-beta.1")
        XCTAssertNil(GitHubRelease.newest(in: releases, above: AppVersion("1.2.0")!, includeBeta: false))
    }

    func testChecksumFromNotes() {
        let hash = String(repeating: "ab", count: 32)
        XCTAssertEqual(GitHubRelease.checksum(inNotes: "**SHA-256:** `\(hash.uppercased())`"), hash)
        XCTAssertNil(GitHubRelease.checksum(inNotes: "no hash here"))
    }

    func testMonitorModeMetersWithoutOutput() {
        let state = RenderState()
        let input = AudioBufferList.allocate(maximumBuffers: 1)
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        for i in 0..<64 { samples[i] = i % 2 == 0 ? 0.5 : -0.25 }
        input[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 64 * 4, mData: samples)
        let output = AudioBufferList.allocate(maximumBuffers: 1)
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        out.initialize(repeating: 9, count: 64)
        output[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 64 * 4, mData: out)
        state.meter(input: input.unsafePointer, output: output.unsafeMutablePointer)
        XCTAssertTrue((0..<64).allSatisfy { out[$0] == 0 }, "monitor mode must not produce sound")
        XCTAssertEqual(state.rms.left, 0.5, accuracy: 0.0001)
        XCTAssertEqual(state.rms.right, 0.25, accuracy: 0.0001)
    }
}

final class AppListingTests: XCTestCase {
    private func app(_ id: String, playing: Bool = false) -> AudioApp {
        AudioApp(bundleID: id, name: id, pid: 1, processObjects: [], isPlaying: playing, isUsingInput: false, isHidden: false)
    }

    func testIdleBackgroundAppsAreHiddenUntilTheyPlay() {
        let prefs = Preferences()
        XCTAssertFalse(AppListing.isListed(app("com.apple.Terminal"), prefs: prefs, rule: nil, hasPlayed: false, selected: false))
        XCTAssertTrue(AppListing.isListed(app("com.apple.Terminal", playing: true), prefs: prefs, rule: nil, hasPlayed: false, selected: false))
        XCTAssertTrue(AppListing.isListed(app("com.apple.Terminal"), prefs: prefs, rule: nil, hasPlayed: true, selected: false))
        XCTAssertTrue(AppListing.isListed(app("x"), prefs: prefs, rule: AppRule(volume: 0.5), hasPlayed: false, selected: false))
        XCTAssertFalse(AppListing.isListed(app("x"), prefs: prefs, rule: AppRule(), hasPlayed: false, selected: false),
                       "a default rule (e.g. written by a profile) doesn't make an idle app listed")
        var showIdle = Preferences()
        showIdle.showIdleApps = true
        XCTAssertTrue(AppListing.isListed(app("com.apple.Terminal"), prefs: showIdle, rule: nil, hasPlayed: false, selected: false))
    }

    func testUserHiddenAppsStayHidden() {
        var prefs = Preferences()
        prefs.hiddenApps = ["com.apple.Terminal"]
        prefs.showIdleApps = true
        XCTAssertFalse(AppListing.isListed(app("com.apple.Terminal", playing: true), prefs: prefs, rule: AppRule(volume: 0.3), hasPlayed: true, selected: true))
    }
}
