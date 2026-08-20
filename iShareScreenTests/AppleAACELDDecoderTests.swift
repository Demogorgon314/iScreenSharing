import XCTest
@testable import iShareScreen

final class AppleAACELDDecoderTests: XCTestCase {
    func testCreatesNativeDecoderWithExpectedOutputFormat() throws {
        let decoder = try AppleAACELDDecoder()
        XCTAssertEqual(decoder.outputFormat.sampleRate, 48_000)
        XCTAssertEqual(decoder.outputFormat.channelCount, 2)
        XCTAssertEqual(AppleAACELDDecoder.magicCookie.count, 43)
    }

    func testRejectsEmptyAccessUnit() throws {
        let decoder = try AppleAACELDDecoder()
        XCTAssertThrowsError(try decoder.decode(Data())) { error in
            XCTAssertEqual(error as? AppleAACELDDecoderError, .invalidAccessUnit)
        }
    }
}
