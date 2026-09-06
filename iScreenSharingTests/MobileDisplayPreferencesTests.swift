import struct ScreenSharingProtocol.AppleCanvas
import XCTest
@testable import iScreenSharing

final class MobileDisplayPreferencesTests: XCTestCase {
    func testRestoresResolutionPerHostAndPort() throws {
        let suite = "MobileDisplayPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = try ConnectionEndpoint("first.local")
        let otherPort = try ConnectionEndpoint(host: "first.local", port: 5901)
        let second = try ConnectionEndpoint("second.local")
        let preferences = MobileResolutionPreferences(defaults: defaults)
        preferences.save(.fullHD, for: first)
        preferences.save(.hd, for: second)

        let restored = MobileResolutionPreferences(defaults: defaults)
        XCTAssertEqual(restored.preset(for: first), .fullHD)
        XCTAssertEqual(restored.preset(for: second), .hd)
        XCTAssertEqual(restored.preset(for: otherPort), .fitScreen)
        restored.save(.fitScreen, for: first)
        XCTAssertEqual(preferences.preset(for: first), .fitScreen)
        XCTAssertNotEqual(
            preferences.preset(for: first).size(for: CGSize(width: 400, height: 800)),
            preferences.preset(for: first).size(for: CGSize(width: 800, height: 400))
        )
        defaults.set("removed-preset", forKey: "MobileResolutionPreset.\(first.url.absoluteString)")
        XCTAssertEqual(restored.preset(for: first), .fitScreen)
    }

    func testPointerAccumulatesSubpixelMotionAndUsesHeightWhenLetterboxed() {
        let canvas = AppleCanvas(width: 1600, height: 1200, tileCount: 4)
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 300)
        var pointer = MobileRemotePointerState()
        let start = pointer.currentPoint(canvas: canvas)
        for _ in 0..<10 {
            _ = pointer.move(by: CGPoint(x: 0.125, y: 0.125), canvas: canvas, bounds: bounds)
        }
        XCTAssertEqual(pointer.point, .init(x: start.x + 5, y: start.y + 5))
        let previous = pointer.point
        _ = pointer.move(by: CGPoint(x: 10, y: 10), canvas: canvas, bounds: .zero)
        _ = pointer.move(by: CGPoint(x: CGFloat.nan, y: 0), canvas: canvas, bounds: bounds)
        XCTAssertEqual(pointer.point, previous)
        _ = pointer.move(by: CGPoint(x: 100_000, y: -100_000), canvas: canvas, bounds: bounds)
        XCTAssertEqual(pointer.point, .init(x: 1599, y: 0))
    }

    func testPointerScreenDistanceSurvivesResolutionAndAspectRatioChanges() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        var pointer = MobileRemotePointerState()
        for canvas in [
            AppleCanvas(width: 1600, height: 1200, tileCount: 4),
            AppleCanvas(width: 3200, height: 2400, tileCount: 4),
            AppleCanvas(width: 1920, height: 1080, tileCount: 4),
        ] {
            let start = pointer.currentPoint(canvas: canvas)
            let end = pointer.move(by: CGPoint(x: 10, y: -5), canvas: canvas, bounds: bounds)
            let displayScale = min(bounds.width / CGFloat(canvas.width), bounds.height / CGFloat(canvas.height))
            XCTAssertEqual(CGFloat(end.x - start.x) * displayScale, 10, accuracy: displayScale)
            XCTAssertEqual(CGFloat(end.y - start.y) * displayScale, -5, accuracy: displayScale)
        }
    }
}
