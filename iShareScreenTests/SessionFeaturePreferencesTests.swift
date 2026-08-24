import XCTest
@testable import iShareScreen

final class SessionFeaturePreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SessionFeaturePreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsPreserveExistingSessionBehavior() {
        let preferences = SessionFeaturePreferences(defaults: defaults)

        XCTAssertFalse(preferences.sharesKeyboardInputSource)
        XCTAssertTrue(preferences.usesDynamicResolution)
        XCTAssertFalse(preferences.mutesAudio)
        XCTAssertNil(preferences.fixedDisplayScale)
        XCTAssertTrue(preferences.synchronizesVideoPresentation)
        XCTAssertFalse(preferences.showsVideoPerformanceOverlay)
        XCTAssertFalse(preferences.showsMetalPerformanceHUD)
    }

    func testPersistsFeatureChoicesForTheNextSession() {
        let preferences = SessionFeaturePreferences(defaults: defaults)
        preferences.setSharesKeyboardInputSource(true)
        preferences.setUsesDynamicResolution(false)
        preferences.setMutesAudio(true)
        preferences.setFixedDisplayScale(1.25)
        preferences.setSynchronizesVideoPresentation(false)
        preferences.setShowsVideoPerformanceOverlay(true)
        preferences.setShowsMetalPerformanceHUD(true)

        let restored = SessionFeaturePreferences(defaults: defaults)

        XCTAssertTrue(restored.sharesKeyboardInputSource)
        XCTAssertFalse(restored.usesDynamicResolution)
        XCTAssertTrue(restored.mutesAudio)
        XCTAssertEqual(restored.fixedDisplayScale, 1.25)
        XCTAssertFalse(restored.synchronizesVideoPresentation)
        XCTAssertTrue(restored.showsVideoPerformanceOverlay)
        XCTAssertTrue(restored.showsMetalPerformanceHUD)
    }

    @MainActor
    func testFeatureModelsWriteChoicesBackForReconnection() {
        let preferences = SessionFeaturePreferences(defaults: defaults)
        let keyboardInputSource = AppleKeyboardInputSourceService(
            currentIdentifier: { "com.apple.keylayout.US" },
            send: { _ in },
            didChangeSharingEnabled: preferences.setSharesKeyboardInputSource
        )
        keyboardInputSource.receive(AppleKeyboardInputSourceState(
            field: 1,
            isSecureInput: false,
            identifier: "com.apple.keylayout.US"
        ))
        keyboardInputSource.setSharingEnabled(true)
        let dynamicResolution = AppleDynamicResolutionModel(
            isEnabled: preferences.usesDynamicResolution,
            didChangeEnabled: preferences.setUsesDynamicResolution
        )
        dynamicResolution.isEnabled = false

        let restored = SessionFeaturePreferences(defaults: defaults)

        XCTAssertTrue(restored.sharesKeyboardInputSource)
        XCTAssertFalse(restored.usesDynamicResolution)
        keyboardInputSource.close()
    }
}
