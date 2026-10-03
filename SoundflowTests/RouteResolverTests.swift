import CoreAudio
import XCTest
@testable import Soundflow

final class RouteResolverTests: XCTestCase {
    private let airpods = "airpods"
    private let display = "display"
    private let macbook = "macbook"

    private func config(priority: [String] = ["airpods", "display", "macbook"]) -> Config {
        var config = Config()
        config.prefs.devicePriority = priority
        return config
    }

    func testEmptyOutputsFollowDefault() {
        let route = RouteResolver.resolve(rule: AppRule(), config: config(), connected: [macbook, airpods], defaultUID: macbook)
        XCTAssertEqual(route.outputs, [macbook])
        XCTAssertTrue(route.followsDefault)
        XCTAssertEqual(route.status, .normal)
    }

    func testExplicitDevice() {
        let route = RouteResolver.resolve(rule: AppRule(outputs: [airpods]), config: config(), connected: [macbook, airpods], defaultUID: macbook)
        XCTAssertEqual(route.outputs, [airpods])
        XCTAssertFalse(route.followsDefault)
    }

    func testFallbackUsesPriorityList() {
        let route = RouteResolver.resolve(rule: AppRule(outputs: [airpods]), config: config(), connected: [macbook, display], defaultUID: macbook)
        XCTAssertEqual(route.outputs, [display])
        XCTAssertEqual(route.status, .fallback(missing: [airpods]))
    }

    func testExplicitFallbackWins() {
        var rule = AppRule(outputs: [airpods])
        rule.fallbackUID = macbook
        let route = RouteResolver.resolve(rule: rule, config: config(), connected: [macbook, display], defaultUID: display)
        XCTAssertEqual(route.outputs, [macbook])
    }

    func testDeviceLevelFallback() {
        var config = config()
        config.devices[airpods] = { var s = DeviceSettings(); s.fallbackUID = macbook; return s }()
        let route = RouteResolver.resolve(rule: AppRule(outputs: [airpods]), config: config, connected: [macbook, display], defaultUID: display)
        XCTAssertEqual(route.outputs, [macbook])
    }

    func testWaitingWhenFallbackDisabled() {
        var rule = AppRule(outputs: [airpods])
        rule.useFallback = false
        let route = RouteResolver.resolve(rule: rule, config: config(), connected: [macbook], defaultUID: macbook)
        XCTAssertTrue(route.isWaiting)
        XCTAssertEqual(route.outputs, [macbook], "waiting apps stay captured (silenced) through the fallback")
    }

    func testMultiOutputExpandsWithClockFirst() {
        var config = config()
        let multi = MultiOutput(name: "Both", deviceUIDs: [airpods, display], clockUID: display)
        config.multiOutputs = [multi]
        let route = RouteResolver.resolve(rule: AppRule(outputs: [multi.ref]), config: config, connected: [airpods, display, macbook], defaultUID: macbook)
        XCTAssertEqual(route.outputs, [display, airpods])
        XCTAssertEqual(route.multiOutputID, multi.id)
    }

    func testPartialMultiOutput() {
        var config = config()
        let multi = MultiOutput(name: "Both", deviceUIDs: [airpods, display])
        config.multiOutputs = [multi]
        let route = RouteResolver.resolve(rule: AppRule(outputs: [multi.ref]), config: config, connected: [display, macbook], defaultUID: macbook)
        XCTAssertEqual(route.outputs, [display])
        XCTAssertEqual(route.status, .partial(available: 1, total: 2))
    }

    func testLatencyAlignmentDelaysFasterDevices() {
        var multi = MultiOutput(name: "Both", deviceUIDs: [airpods, display])
        multi.alignLatency = true
        multi.delays = [airpods: 5]
        let delays = RouteResolver.alignment(for: multi, outputs: [airpods, display], latencies: [airpods: 160, display: 10])
        XCTAssertEqual(delays[display] ?? 0, 150, accuracy: 0.01)
        XCTAssertEqual(delays[airpods] ?? 0, 5, accuracy: 0.01)
    }

    func testNeedsTap() {
        let normal = ResolvedRoute(outputs: [macbook], followsDefault: true)
        XCTAssertFalse(RouteResolver.needsTap(rule: AppRule(), route: normal, defaultUID: macbook, gainFactor: 1, normalize: false))
        XCTAssertTrue(RouteResolver.needsTap(rule: AppRule(volume: 0.5), route: normal, defaultUID: macbook, gainFactor: 1, normalize: false))
        XCTAssertTrue(RouteResolver.needsTap(rule: AppRule(), route: normal, defaultUID: macbook, gainFactor: 0.4, normalize: false))
        let explicit = ResolvedRoute(outputs: [airpods], followsDefault: false)
        XCTAssertTrue(RouteResolver.needsTap(rule: AppRule(outputs: [airpods]), route: explicit, defaultUID: macbook, gainFactor: 1, normalize: false))
        let explicitDefault = ResolvedRoute(outputs: [macbook], followsDefault: false)
        XCTAssertFalse(RouteResolver.needsTap(rule: AppRule(outputs: [macbook]), route: explicitDefault, defaultUID: macbook, gainFactor: 1, normalize: false))
    }
}

final class ProfileTriggerTests: XCTestCase {
    private func context(_ string: String, devices: Set<String> = [], apps: Set<String> = [], ssid: String? = nil) -> TriggerContext {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return TriggerContext(connectedDevices: devices, runningApps: apps, ssid: ssid, date: formatter.date(from: string)!, calendar: calendar)
    }

    func testWeekdayNumbering() {
        XCTAssertEqual(context("2026-10-05T10:00:00Z").weekday, 1) // Monday
        XCTAssertEqual(context("2026-10-04T10:00:00Z").weekday, 7) // Sunday
    }

    func testDaytimeSchedule() {
        let workdays = ProfileTrigger.schedule(weekdays: Set(1...5), start: 9 * 60, end: 18 * 60)
        XCTAssertTrue(ProfileManager.matches(workdays, context("2026-10-05T10:00:00Z")))
        XCTAssertFalse(ProfileManager.matches(workdays, context("2026-10-05T18:30:00Z")))
        XCTAssertFalse(ProfileManager.matches(workdays, context("2026-10-04T10:00:00Z")))
    }

    func testOvernightSchedule() {
        // Friday night only: 23:00–7:00 belongs to Friday, so Saturday 02:00 matches.
        let friday = ProfileTrigger.schedule(weekdays: [5], start: 23 * 60, end: 7 * 60)
        XCTAssertTrue(ProfileManager.matches(friday, context("2026-10-09T23:30:00Z")))
        XCTAssertTrue(ProfileManager.matches(friday, context("2026-10-10T02:00:00Z")))
        XCTAssertFalse(ProfileManager.matches(friday, context("2026-10-10T08:00:00Z")))
        XCTAssertFalse(ProfileManager.matches(friday, context("2026-10-08T23:30:00Z")))
    }

    func testOtherTriggers() {
        let ctx = context("2026-10-05T10:00:00Z", devices: ["airpods"], apps: ["us.zoom.xos"], ssid: "Office")
        XCTAssertTrue(ProfileManager.matches(.deviceConnected(uid: "airpods"), ctx))
        XCTAssertFalse(ProfileManager.matches(.deviceConnected(uid: "display"), ctx))
        XCTAssertTrue(ProfileManager.matches(.appRunning(bundleID: "us.zoom.xos"), ctx))
        XCTAssertTrue(ProfileManager.matches(.wifi(ssid: "Office"), ctx))
        XCTAssertFalse(ProfileManager.matches(.wifi(ssid: "Home"), ctx))
    }
}

final class RenderStateTests: XCTestCase {
    /// Builds an AudioBufferList with the given (channels, frames) buffers filled by `fill`.
    private func makeList(_ layout: [(channels: Int, frames: Int)], fill: (Int, Int, Int) -> Float) -> UnsafeMutableAudioBufferListPointer {
        let list = AudioBufferList.allocate(maximumBuffers: layout.count)
        for (index, item) in layout.enumerated() {
            let count = item.channels * item.frames
            let data = UnsafeMutablePointer<Float>.allocate(capacity: count)
            for frame in 0..<item.frames {
                for channel in 0..<item.channels { data[frame * item.channels + channel] = fill(index, frame, channel) }
            }
            list[index] = AudioBuffer(mNumberChannels: UInt32(item.channels), mDataByteSize: UInt32(count * 4), mData: data)
        }
        return list
    }

    private func samples(_ list: UnsafeMutableAudioBufferListPointer, buffer: Int) -> [Float] {
        let item = list[buffer]
        let count = Int(item.mDataByteSize) / 4
        return Array(UnsafeBufferPointer(start: item.mData!.assumingMemoryBound(to: Float.self), count: count))
    }

    func testCopiesInterleavedStereoToEveryOutputWithGain() {
        let state = RenderState()
        state.targetGain = 0.5
        // Settle the gain ramp first.
        let input = makeList([(2, 64)]) { _, _, channel in channel == 0 ? 0.8 : -0.4 }
        let output = makeList([(2, 64), (2, 64)]) { _, _, _ in 9 }
        state.render(input: input.unsafePointer, output: output.unsafeMutablePointer)
        state.render(input: input.unsafePointer, output: output.unsafeMutablePointer)
        for buffer in 0..<2 {
            let out = samples(output, buffer: buffer)
            XCTAssertEqual(out[0], 0.4, accuracy: 0.0001)
            XCTAssertEqual(out[1], -0.2, accuracy: 0.0001)
        }
        XCTAssertGreaterThan(state.peak.left, 0.39)
    }

    func testSkipsSubDeviceInputsAndMixesToMono() {
        let state = RenderState()
        state.inputOffset = 1
        let input = makeList([(1, 32), (2, 32)]) { buffer, _, channel in buffer == 0 ? 1 : (channel == 0 ? 0.2 : 0.6) }
        let output = makeList([(1, 32)]) { _, _, _ in 0 }
        state.render(input: input.unsafePointer, output: output.unsafeMutablePointer)
        XCTAssertEqual(samples(output, buffer: 0)[31], 0.4, accuracy: 0.0001)
    }

    func testBalanceAndExtraChannels() {
        let state = RenderState()
        state.balance = 1 // full right
        let input = makeList([(2, 16)]) { _, _, _ in 0.5 }
        let output = makeList([(4, 16)]) { _, _, _ in 7 }
        state.render(input: input.unsafePointer, output: output.unsafeMutablePointer)
        let out = samples(output, buffer: 0)
        XCTAssertEqual(out[4 * 15], 0, accuracy: 0.0001)
        XCTAssertEqual(out[4 * 15 + 1], 0.5, accuracy: 0.0001)
        XCTAssertEqual(out[4 * 15 + 2], 0)
        XCTAssertEqual(out[4 * 15 + 3], 0)
    }

    func testSilenceWhenNoTapInput() {
        let state = RenderState()
        state.inputOffset = 3
        let input = makeList([(2, 8)]) { _, _, _ in 1 }
        let output = makeList([(2, 8)]) { _, _, _ in 5 }
        state.render(input: input.unsafePointer, output: output.unsafeMutablePointer)
        XCTAssertTrue(samples(output, buffer: 0).allSatisfy { $0 == 0 })
    }
}

final class ModelTests: XCTestCase {
    func testConfigRoundTripAndTolerantDecoding() throws {
        var config = Config()
        config.appRules["com.spotify.client"] = AppRule(volume: 0.72, outputs: ["airpods"])
        config.prefs.hotkeys[.muteAll] = Hotkey(key: .m, modifiers: [.control, .option])
        let data = try JSONEncoder.soundflow.encode(config)
        XCTAssertEqual(try JSONDecoder.soundflow.decode(Config.self, from: data), config)

        let partial = #"{"appRules":{"x":{"volume":0.5}},"prefs":{"normalize":true}}"#.data(using: .utf8)!
        let decoded = try JSONDecoder.soundflow.decode(Config.self, from: partial)
        XCTAssertEqual(decoded.appRules["x"]?.volume, 0.5)
        XCTAssertEqual(decoded.appRules["x"]?.remember, true)
        XCTAssertTrue(decoded.prefs.normalize)
        XCTAssertEqual(decoded.profiles.count, 4)
    }

    func testRussianPlurals() {
        XCTAssertEqual(countText(1, "приложение", "приложения", "приложений"), "1 приложение")
        XCTAssertEqual(countText(3, "приложение", "приложения", "приложений"), "3 приложения")
        XCTAssertEqual(countText(7, "приложение", "приложения", "приложений"), "7 приложений")
        XCTAssertEqual(countText(11, "приложение", "приложения", "приложений"), "11 приложений")
        XCTAssertEqual(countText(22, "приложение", "приложения", "приложений"), "22 приложения")
    }

    func testHotkeyCaps() {
        XCTAssertEqual(Hotkey(key: .s, modifiers: [.command, .option]).caps, ["⌥", "⌘", "S"])
        XCTAssertEqual(Hotkey(key: .up, modifiers: [.control, .option]).display, "⌃ ⌥ ↑")
    }
}
