import struct ScreenSharingProtocol.AppleRemoteDeviceInfo
import XCTest
@testable import iScreenSharing

@MainActor
final class RemoteDeviceIconTests: XCTestCase {
    func testResolvesDeclaredSystemHardwareTypeFromDeviceModel() throws {
        let type = try XCTUnwrap(RemoteHardwareIcon.contentType(for: AppleRemoteDeviceInfo(
            modelIdentifier: "Mac16,10",
            deviceColor: "0"
        )))

        XCTAssertTrue(type.isDeclared)
        XCTAssertFalse(type.isDynamic)
    }

    func testRejectsUnknownDeviceModelInsteadOfUsingDynamicType() {
        XCTAssertNil(RemoteHardwareIcon.contentType(for: AppleRemoteDeviceInfo(
            modelIdentifier: "UnknownMac999,999"
        )))
    }
}
