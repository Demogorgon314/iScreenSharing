import Darwin
import XCTest
@testable import iShareScreen

final class AppleMediaReceiverTests: XCTestCase {
    func testVideoSocketsUseSystemDefaultReceiveBuffer() {
        XCTAssertNil(AppleMediaReceiver.requestedVideoReceiveBufferBytes)
    }

    func testDebugReceiveBufferOverrideRejectsInvalidValues() {
        XCTAssertNil(AppleMediaReceiver.requestedVideoReceiveBufferBytes(environment: [:]))
        XCTAssertNil(AppleMediaReceiver.requestedVideoReceiveBufferBytes(
            environment: ["ISHARESCREEN_VIDEO_RCVBUF_BYTES": "0"]
        ))
        XCTAssertNil(AppleMediaReceiver.requestedVideoReceiveBufferBytes(
            environment: ["ISHARESCREEN_VIDEO_RCVBUF_BYTES": "invalid"]
        ))
    }

    func testDebugReceiveBufferOverrideAcceptsPositiveInt32Value() {
#if DEBUG
        XCTAssertEqual(
            AppleMediaReceiver.requestedVideoReceiveBufferBytes(
                environment: ["ISHARESCREEN_VIDEO_RCVBUF_BYTES": "4194304"]
            ),
            4_194_304
        )
#else
        XCTAssertNil(AppleMediaReceiver.requestedVideoReceiveBufferBytes(
            environment: ["ISHARESCREEN_VIDEO_RCVBUF_BYTES": "4194304"]
        ))
#endif
    }

    func testReadsActualReceiveBufferSizeFromSocket() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }

        let receiveBufferSize = try XCTUnwrap(
            AppleMediaReceiver.receiveBufferSize(of: descriptor)
        )

        XCTAssertGreaterThan(receiveBufferSize, 0)
    }
}
