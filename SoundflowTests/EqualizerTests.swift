import CoreAudio
import XCTest
@testable import Soundflow

final class EqualizerTests: XCTestCase {
    func testFlatIsIdentity() {
        XCTAssertTrue(Equalizer.filters(for: EQSettings(), sampleRate: 48000).allSatisfy { $0 == .identity })
        XCTAssertFalse(EQSettings().isActive)
        XCTAssertFalse(EQSettings(enabled: false, gains: EQPreset.bass.gains).isActive)
    }

    func testPeakingGainAtCenterFrequency() {
        let filter = Biquad.make(.peaking, frequency: 1000, gainDB: 6, sampleRate: 48000)
        XCTAssertEqual(filter.responseDB(at: 1000, sampleRate: 48000), 6, accuracy: 0.05)
        XCTAssertEqual(filter.responseDB(at: 10, sampleRate: 48000), 0, accuracy: 0.2)
    }

    func testShelves() {
        let low = Biquad.make(.lowShelf, frequency: 32, gainDB: 8, sampleRate: 48000)
        XCTAssertEqual(low.responseDB(at: 5, sampleRate: 48000), 8, accuracy: 0.3)
        XCTAssertEqual(low.responseDB(at: 4000, sampleRate: 48000), 0, accuracy: 0.1)
        let high = Biquad.make(.highShelf, frequency: 16000, gainDB: -6, sampleRate: 48000)
        XCTAssertLessThan(high.responseDB(at: 21000, sampleRate: 48000), -4)
    }

    func testFiltersAreStable() {
        for preset in EQPreset.allCases {
            for filter in Equalizer.filters(for: EQSettings(gains: preset.gains), sampleRate: 44100) {
                // Poles inside the unit circle: |a2| < 1 and |a1| < 1 + a2.
                XCTAssertLessThan(abs(filter.a2), 1, preset.title)
                XCTAssertLessThan(abs(filter.a1), 1 + filter.a2, preset.title)
            }
        }
    }

    func testDecodingPadsAndClampsGains() throws {
        let json = #"{"gains":[20,-20,3]}"#
        let eq = try JSONDecoder().decode(EQSettings.self, from: Data(json.utf8))
        XCTAssertEqual(eq.gains.count, 10)
        XCTAssertEqual(eq.gains[0], 12)
        XCTAssertEqual(eq.gains[1], -12)
        XCTAssertEqual(eq.gains[9], 0)
    }

    func testRenderAppliesBassBoost() {
        // A 60 Hz sine through the "Бас+" preset must come out louder than through a flat EQ.
        func outputRMS(eq: EQSettings?) -> Float {
            let state = RenderState()
            state.setEqualizer(eq.map { Equalizer.filters(for: $0, sampleRate: 48000) })
            let frames = 4096
            let input = AudioBufferList.allocate(maximumBuffers: 1)
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
            for i in 0..<frames {
                let v = Float(sin(2 * Double.pi * 60 * Double(i) / 48000)) * 0.2
                samples[i * 2] = v
                samples[i * 2 + 1] = v
            }
            input[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: samples)
            let output = AudioBufferList.allocate(maximumBuffers: 1)
            let out = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
            output[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: out)
            state.render(input: input.unsafePointer, output: output.unsafeMutablePointer)
            var sum: Float = 0
            for i in (frames / 2)..<frames { sum += out[i * 2] * out[i * 2] }
            return (sum / Float(frames / 2)).squareRoot()
        }
        let flat = outputRMS(eq: nil)
        let bass = outputRMS(eq: EQSettings(gains: EQPreset.bass.gains))
        XCTAssertGreaterThan(20 * log10(bass / flat), 4, "bass preset should add ≥4 dB at 60 Hz")
    }
}

final class SpectrumTests: XCTestCase {
    func testSineLandsInMatchingBand() {
        let analyzer = SpectrumAnalyzer(size: 2048, bandCount: 40)
        let sine = (0..<2048).map { Float(sin(2 * Double.pi * 1000 * Double($0) / 48000)) * 0.5 }
        for _ in 0..<10 { analyzer.analyze(sine, sampleRate: 48000) }
        let edges = SpectrumAnalyzer.bandEdges(count: 40)
        let expected = edges.indices.dropLast().first { edges[$0] <= 1000 && 1000 < edges[$0 + 1] }!
        let loudest = analyzer.bands.indices.max { analyzer.bands[$0] < analyzer.bands[$1] }!
        XCTAssertLessThanOrEqual(abs(loudest - expected), 1)
        XCTAssertGreaterThan(analyzer.bands[loudest], 0.7)
        XCTAssertLessThan(analyzer.bands[0], 0.2, "low bands stay quiet for a 1 kHz tone")
    }

    func testRingBufferKeepsLatestSamples() {
        let state = RenderState()
        state.capturesSpectrum = true
        let frames = 6000 // more than the ring holds
        let input = AudioBufferList.allocate(maximumBuffers: 1)
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        for i in 0..<frames { samples[i * 2] = Float(i); samples[i * 2 + 1] = Float(i) }
        input[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: samples)
        let output = AudioBufferList.allocate(maximumBuffers: 1)
        let out = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        output[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: out)
        state.meter(input: input.unsafePointer, output: output.unsafeMutablePointer)
        var recent = [Float](repeating: 0, count: 4)
        recent.withUnsafeMutableBufferPointer { state.recentSamples(into: $0.baseAddress!, count: 4) }
        XCTAssertEqual(recent, [5996, 5997, 5998, 5999])
    }
}
