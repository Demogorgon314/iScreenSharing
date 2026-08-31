import struct ScreenSharingProtocol.AppleKeyboardInputSourceState
import XCTest
@testable import iScreenSharing

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
        XCTAssertNil(preferences.fixedDisplayScale)
        XCTAssertTrue(preferences.synchronizesVideoPresentation)
        XCTAssertFalse(preferences.showsVideoPerformanceOverlay)
        XCTAssertEqual(preferences.videoPerformanceLevel, .compact)
        XCTAssertEqual(preferences.videoDecoderMode, .videoProcessing)
        XCTAssertFalse(preferences.showsMetalPerformanceHUD)
    }

    func testPersistsFeatureChoicesForTheNextSession() {
        let preferences = SessionFeaturePreferences(defaults: defaults)
        preferences.setSharesKeyboardInputSource(true)
        preferences.setUsesDynamicResolution(false)
        preferences.setFixedDisplayScale(1.25)
        preferences.setSynchronizesVideoPresentation(false)
        preferences.setShowsVideoPerformanceOverlay(true)
        preferences.setVideoPerformanceLevel(.detailed)
        preferences.setVideoDecoderMode(.videoToolboxSynchronized)
        preferences.setShowsMetalPerformanceHUD(true)

        let restored = SessionFeaturePreferences(defaults: defaults)

        XCTAssertTrue(restored.sharesKeyboardInputSource)
        XCTAssertFalse(restored.usesDynamicResolution)
        XCTAssertEqual(restored.fixedDisplayScale, 1.25)
        XCTAssertFalse(restored.synchronizesVideoPresentation)
        XCTAssertTrue(restored.showsVideoPerformanceOverlay)
        XCTAssertEqual(restored.videoPerformanceLevel, .detailed)
        XCTAssertEqual(restored.videoDecoderMode, .videoToolboxSynchronized)
        XCTAssertEqual(
            defaults.string(forKey: SessionFeaturePreferences.videoDecoderModeKey),
            "videoToolboxSynchronized"
        )
        XCTAssertTrue(restored.showsMetalPerformanceHUD)
    }

    func testMigratesLegacyMetricTogglesToPerformanceLevels() {
        defaults.set(true, forKey: SessionFeaturePreferences.showsDetailedVideoMetricsKey)
        XCTAssertEqual(
            SessionFeaturePreferences(defaults: defaults).videoPerformanceLevel,
            .detailed
        )

        defaults.set(true, forKey: SessionFeaturePreferences.showsMoonlightStyleMetricsKey)
        XCTAssertEqual(
            SessionFeaturePreferences(defaults: defaults).videoPerformanceLevel,
            .compact
        )
    }

    func testInvalidPerformanceLevelFallsBackToCompact() {
        defaults.set("unsupported", forKey: SessionFeaturePreferences.videoPerformanceLevelKey)

        XCTAssertEqual(
            SessionFeaturePreferences(defaults: defaults).videoPerformanceLevel,
            .compact
        )
    }

    func testInvalidVideoDecoderModeFallsBackToVideoProcessing() {
        defaults.set("unsupported", forKey: SessionFeaturePreferences.videoDecoderModeKey)

        XCTAssertEqual(
            SessionFeaturePreferences(defaults: defaults).videoDecoderMode,
            .videoProcessing
        )
    }

    func testMigratesAutomaticVideoDecoderModeToVideoProcessing() {
        defaults.set("automatic", forKey: SessionFeaturePreferences.videoDecoderModeKey)

        XCTAssertEqual(
            SessionFeaturePreferences(defaults: defaults).videoDecoderMode,
            .videoProcessing
        )
    }

    func testStandardVideoDecoderModesExcludeExperimentalChoices() {
        XCTAssertEqual(
            AppleVideoDecoderMode.standardCases,
            [.videoProcessing, .videoToolboxSynchronized]
        )
        XCTAssertEqual(
            AppleVideoDecoderMode.videoToolboxSynchronized.title,
            "VideoToolbox (Seamless)"
        )
        XCTAssertFalse(AppleVideoDecoderMode.standardCases.contains(.videoToolboxLowLatency))
        XCTAssertFalse(AppleVideoDecoderMode.standardCases.contains(.automatic))
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
