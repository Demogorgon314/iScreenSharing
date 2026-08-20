import XCTest
@testable import iShareScreen

final class AppleHEVCDecoderTests: XCTestCase {
    func testBuildsFourByteLengthPrefixedPayload() throws {
        let unit = Data([0x26, 0x01, 0xaa, 0xbb])
        XCTAssertEqual(
            try AppleHEVCDecoder.lengthPrefixedPayload(for: unit),
            Data([0, 0, 0, 4, 0x26, 0x01, 0xaa, 0xbb])
        )
    }

    func testRejectsEmptyNALUnitPayload() {
        XCTAssertThrowsError(try AppleHEVCDecoder.lengthPrefixedPayload(for: Data())) { error in
            XCTAssertEqual(error as? AppleHEVCDecoderError, .invalidNALUnit)
        }
    }

    func testRejectsIncompleteParameterSets() {
        XCTAssertThrowsError(
            try AppleHEVCDecoder(parameterSets: AppleHEVCParameterSets()) { _, _ in }
        ) { error in
            XCTAssertEqual(error as? AppleHEVCDecoderError, .incompleteParameterSets)
        }
    }
}
