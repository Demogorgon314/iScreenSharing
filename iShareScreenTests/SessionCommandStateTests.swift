import AppKit
import Combine
import XCTest
@testable import iShareScreen

@MainActor
final class SessionCommandStateTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SessionCommandStateTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testLoadsAndPersistsPresentationChoices() throws {
        let preferences = SessionFeaturePreferences(defaults: defaults)
        preferences.setFixedDisplayScale(1.25)
        preferences.setSynchronizesVideoPresentation(false)
        preferences.setShowsVideoPerformanceOverlay(true)
        preferences.setShowsMetalPerformanceHUD(true)
        let state = SessionCommandState(
            endpoint: try ConnectionEndpoint(host: "command-state.test"),
            preferences: preferences
        )

        XCTAssertEqual(state.displayScale.fixedScale, 1.25)
        XCTAssertFalse(state.synchronizesVideoPresentation)
        XCTAssertTrue(state.showsVideoPerformanceOverlay)
        XCTAssertTrue(state.showsMetalPerformanceHUD)

        state.setScalesToFit(true)
        state.setSynchronizesVideoPresentation(true)
        state.setShowsVideoPerformanceOverlay(false)
        state.setShowsMetalPerformanceHUD(false)

        let restored = SessionFeaturePreferences(defaults: defaults)
        XCTAssertNil(restored.fixedDisplayScale)
        XCTAssertTrue(restored.synchronizesVideoPresentation)
        XCTAssertFalse(restored.showsVideoPerformanceOverlay)
        XCTAssertFalse(restored.showsMetalPerformanceHUD)
    }

    func testRouterTracksTheMostRecentlyActivatedSession() throws {
        let router = ActiveSessionCommandRouter()
        let first = SessionCommandState(
            endpoint: try ConnectionEndpoint(host: "first.test"),
            preferences: SessionFeaturePreferences(defaults: defaults)
        )
        let second = SessionCommandState(
            endpoint: try ConnectionEndpoint(host: "second.test"),
            preferences: SessionFeaturePreferences(defaults: defaults)
        )
        let firstWindow = makeWindow()
        let secondWindow = makeWindow()

        router.activate(first, for: firstWindow)
        XCTAssertTrue(router.active === first)

        router.activate(second, for: secondWindow)
        XCTAssertTrue(router.active === second)

        router.deactivate(window: firstWindow)
        XCTAssertTrue(router.active === second)

        router.deactivate(window: secondWindow)
        XCTAssertNil(router.active)
    }

    func testRouterForwardsChangesFromTheActiveSessionOnly() throws {
        let router = ActiveSessionCommandRouter()
        let active = SessionCommandState(
            endpoint: try ConnectionEndpoint(host: "active.test"),
            preferences: SessionFeaturePreferences(defaults: defaults)
        )
        let inactive = SessionCommandState(
            endpoint: try ConnectionEndpoint(host: "inactive.test"),
            preferences: SessionFeaturePreferences(defaults: defaults)
        )
        let window = makeWindow()
        router.activate(active, for: window)

        var changeCount = 0
        let subscription = router.objectWillChange.sink { changeCount += 1 }

        inactive.setSynchronizesVideoPresentation(false)
        XCTAssertEqual(changeCount, 0)

        active.setSynchronizesVideoPresentation(false)
        XCTAssertEqual(changeCount, 1)
        withExtendedLifetime(subscription) { }
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }
}
