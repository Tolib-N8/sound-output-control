import SwiftUI
import XCTest
@testable import Soundflow

final class IconTests: XCTestCase {
    func testParsesLinesAndClose() {
        let rect = SVGPath.parse("M4 4h16v16H4z").boundingRect
        XCTAssertEqual(rect, CGRect(x: 4, y: 4, width: 16, height: 16))
    }

    func testParsesArcsWithCompactFlags() {
        // A circle of radius 10 around (12, 12), written with relative arcs.
        let circle = SVGPath.parse("M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0z").boundingRect
        XCTAssertEqual(circle.minX, 2, accuracy: 0.05)
        XCTAssertEqual(circle.maxX, 22, accuracy: 0.05)
        XCTAssertEqual(circle.minY, 2, accuracy: 0.05)
        XCTAssertEqual(circle.maxY, 22, accuracy: 0.05)
        // "0 0018.5 8" = flags 0, 0 then x 18.5 — no separators between flags and the next number.
        let compact = SVGPath.parse("M22 11.5A3.5 3.5 0 0018.5 8").boundingRect
        XCTAssertEqual(compact.minX, 18.5, accuracy: 0.05)
        XCTAssertEqual(compact.maxX, 22, accuracy: 0.05)
    }

    func testParsesCompactNumbers() {
        let path = SVGPath.parse("M11 4.702a.705.705 0 0 0-1.203-.498L6.413 7.587").boundingRect
        XCTAssertEqual(path.minX, 6.413, accuracy: 0.01)
        XCTAssertEqual(path.maxX, 11, accuracy: 0.05)
    }

    func testEveryIconParsesInsideItsViewBox() {
        for (name, parts) in LucideGlyphs.paths {
            for (index, data) in parts.enumerated() {
                let box = SVGPath.parse(data).boundingRect
                XCTAssertFalse(box.isNull, "\(name)[\(index)] is empty")
                XCTAssertTrue(CGRect(x: -0.5, y: -0.5, width: 25, height: 25).contains(box), "\(name)[\(index)] out of bounds: \(box)")
            }
        }
    }

    /// Motions must end in the resting pose so icons never stay displaced after an animation.
    func testMotionsReturnToRest() {
        // Rotations by a symmetry angle end visually identical but not as an identity matrix.
        let symmetric: Set<String> = ["plus", "x", "star", "settings", "rotate-ccw", "refresh-cw", "life-buoy", "volume-x", "clock-3", "gamepad-2"]
        for (name, parts) in LucideGlyphs.paths {
            let motion = IconMotions.motion(for: name)
            XCTAssertGreaterThan(motion.duration, 0.2, name)
            for index in parts.indices {
                let part = motion.part?(index, 1) ?? PartPose()
                let whole = motion.whole?(1) ?? PartPose()
                XCTAssertEqual(part.opacity * whole.opacity, 1, accuracy: 0.001, "\(name)[\(index)] opacity")
                XCTAssertEqual(part.trim, 0...1, "\(name)[\(index)] trim")
                guard !symmetric.contains(name) else { continue }
                let t = part.transform.concatenating(whole.transform)
                for value in [t.a - 1, t.b, t.c, t.d - 1, t.tx, t.ty] {
                    XCTAssertEqual(value, 0, accuracy: 0.001, "\(name)[\(index)] transform \(t)")
                }
            }
        }
    }
}
