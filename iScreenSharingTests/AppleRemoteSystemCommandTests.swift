import XCTest
@testable import iScreenSharing

final class AppleRemoteSystemCommandTests: XCTestCase {
    func testNativeVendorKeySymbols() {
        XCTAssertEqual(AppleRemoteSystemCommand.launchpad.rawValue, 0x1008_fd00)
        XCTAssertEqual(AppleRemoteSystemCommand.desktop.rawValue, 0x1008_fd01)
        XCTAssertEqual(AppleRemoteSystemCommand.missionControl.rawValue, 0x1008_fd02)
        XCTAssertEqual(AppleRemoteSystemCommand.appWindows.rawValue, 0x1008_fd03)
    }

    @MainActor
    func testCapabilitiesReplacePreviouslyAdvertisedCommands() {
        let capabilities = AppleRemoteSystemCapabilities()
        capabilities.receive(keySymbols: [
            AppleRemoteSystemCommand.launchpad.rawValue,
            AppleRemoteSystemCommand.missionControl.rawValue,
        ])
        XCTAssertTrue(capabilities.supports(.launchpad))
        XCTAssertTrue(capabilities.supports(.missionControl))
        XCTAssertFalse(capabilities.supports(.desktop))

        capabilities.receive(keySymbols: [AppleRemoteSystemCommand.desktop.rawValue])
        XCTAssertFalse(capabilities.supports(.launchpad))
        XCTAssertTrue(capabilities.supports(.desktop))
    }
}

