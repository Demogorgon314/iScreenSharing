import Network
import struct ScreenSharingProtocol.AppleRemoteDeviceInfo
import XCTest
@testable import iScreenSharing

final class BonjourBrowserTests: XCTestCase {
    func testConvertsServiceEndpointToDomainModel() throws {
        let networkEndpoint = NWEndpoint.service(
            name: "Shared Mac",
            type: "_rfb._tcp",
            domain: "local.",
            interface: nil
        )

        let endpoint = try XCTUnwrap(BonjourBrowser.connectionEndpoint(from: networkEndpoint))

        XCTAssertEqual(endpoint.displayName, "Shared Mac")
        XCTAssertEqual(endpoint.bonjourService?.type, "_rfb._tcp")
        XCTAssertEqual(endpoint.bonjourService?.domain, "local.")
    }

    func testIgnoresNonServiceEndpoint() {
        XCTAssertNil(
            BonjourBrowser.connectionEndpoint(
                from: .hostPort(host: "example.local", port: 5900)
            )
        )
    }

    func testParsesDeviceInfoTXTRecord() {
        let data = txtRecord([
            "model=Mac16,10",
            "osxvers=25",
            "icolor=1",
            "unknown=value",
        ])

        XCTAssertEqual(
            BonjourDeviceInfoTXT.parse(data),
            AppleRemoteDeviceInfo(modelIdentifier: "Mac16,10", deviceColor: "1")
        )
    }

    func testRejectsMalformedOrMissingDeviceModelTXTRecord() {
        XCTAssertNil(BonjourDeviceInfoTXT.parse(txtRecord(["icolor=1"])))
        XCTAssertNil(BonjourDeviceInfoTXT.parse(Data([5, 65, 66])))
        XCTAssertNil(BonjourDeviceInfoTXT.parse(Data([2, 0xff, 0xff])))
    }

    private func txtRecord(_ entries: [String]) -> Data {
        var data = Data()
        for entry in entries {
            let bytes = Data(entry.utf8)
            data.append(UInt8(bytes.count))
            data.append(bytes)
        }
        return data
    }
}
