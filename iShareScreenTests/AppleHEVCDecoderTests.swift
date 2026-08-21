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
            try AppleHEVCDecoder(parameterSets: AppleHEVCParameterSets()) { _, _, _ in }
        ) { error in
            XCTAssertEqual(error as? AppleHEVCDecoderError, .incompleteParameterSets)
        }
    }

    func testRequiresDecoderReplacementWhenParameterSetsChange() {
        let configured = AppleHEVCParameterSets(
            video: Data([1]),
            sequence: Data([2]),
            pictures: [Data([3])]
        )
        let changed = AppleHEVCParameterSets(
            video: Data([1]),
            sequence: Data([4]),
            pictures: [Data([3])]
        )

        XCTAssertFalse(AppleHEVCDecoder.requiresReplacement(
            configured: configured,
            current: configured
        ))
        XCTAssertTrue(AppleHEVCDecoder.requiresReplacement(
            configured: configured,
            current: changed
        ))
        XCTAssertFalse(AppleHEVCDecoder.requiresReplacement(
            configured: configured,
            current: AppleHEVCParameterSets()
        ))
    }
}
