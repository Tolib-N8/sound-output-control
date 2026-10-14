import AppKit
import SwiftUI
import XCTest
@testable import Soundflow

final class NowPlayingTests: XCTestCase {
    func testParsesHelperEvent() {
        let event: [String: Any] = ["type": "state", "title": "Veridis Quo", "artist": "Daft Punk", "album": "Discovery",
                                    "duration": 344.5, "elapsed": 100.0, "rate": 1.0, "timestamp": 1_000_000.0,
                                    "playing": true, "pid": 42, "artworkId": "abc"]
        let state = NowPlaying.parse(event)!
        XCTAssertEqual(state.title, "Veridis Quo")
        XCTAssertEqual(state.subtitle, "Daft Punk — Discovery")
        XCTAssertEqual(state.duration, 344.5)
        XCTAssertEqual(state.pid, 42)
        XCTAssertTrue(state.isPlaying)
        // 10 s after the report the track is 10 s further, and never past its end.
        XCTAssertEqual(state.position(at: Date(timeIntervalSince1970: 1_000_010)), 110, accuracy: 0.001)
        XCTAssertEqual(state.position(at: Date(timeIntervalSince1970: 1_001_000)), 344.5, accuracy: 0.001)
    }

    func testPausedPositionDoesNotMove() {
        let state = NowPlaying.parse(["title": "x", "elapsed": 12.0, "rate": 0.0, "playing": false, "timestamp": 0.0])!
        XCTAssertEqual(state.position(at: Date(timeIntervalSince1970: 500)), 12)
        XCTAssertNil(state.duration)
    }

    func testEmptyEventMeansNothingPlaying() {
        XCTAssertNil(NowPlaying.parse(["type": "state", "playing": false, "pid": 0]))
    }

    @MainActor
    func testPaletteFromColorfulAndGrayArtwork() {
        func image(_ color: NSColor) -> NSImage {
            NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
                color.setFill(); rect.fill(); return true
            }
        }
        let red = ArtworkPalette.extract(from: image(NSColor(deviceRed: 0.85, green: 0.1, blue: 0.2, alpha: 1)))
        XCTAssertFalse(red.isDefault)
        let gray = ArtworkPalette.extract(from: image(NSColor(deviceWhite: 0.5, alpha: 1)))
        XCTAssertTrue(gray.isDefault, "grayscale art falls back to the brand accent")
    }
}
