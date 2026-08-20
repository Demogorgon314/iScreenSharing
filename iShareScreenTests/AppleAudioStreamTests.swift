import XCTest
@testable import iShareScreen

final class AppleAudioStreamTests: XCTestCase {
    func testRecognizesOnlyAppleAudioRTPPayload() {
        var audio = Data(repeating: 0, count: 12)
        audio[0] = 0x80
        audio[1] = 101
        XCTAssertTrue(AppleAudioStream.isAudioRTP(audio))

        audio[1] = 72
        XCTAssertFalse(AppleAudioStream.isAudioRTP(audio))
        audio[0] = 0
        audio[1] = 101
        XCTAssertFalse(AppleAudioStream.isAudioRTP(audio))
    }
}
