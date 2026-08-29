import Foundation
import XCTest
import ScreenSharingProtocol

final class AppleHEVCSubframeBoundaryParserTests: XCTestCase {
    func testMatchesNativeFLSControlSequence() throws {
        let parser = try XCTUnwrap(AppleHEVCSubframeBoundaryParser(
            negotiationDetails: "FLS;LF:-1;POS:5;EOD:1;HTS:2;RR:3;POSE:4;"
        ))

        XCTAssertEqual(parser.classify(nalUnits: [slice(controlByte: 0x80)]), .notLast)
        XCTAssertEqual(parser.classify(nalUnits: [slice(controlByte: 0x82)]), .last)
    }

    func testUsesLastVCLUnitAndIgnoresFollowingNonVCLUnit() throws {
        let parser = try makeParser()
        let suffixSEI = Data([0x50, 0x01, 0x80])

        XCTAssertEqual(
            parser.classify(nalUnits: [slice(controlByte: 0x82), suffixSEI]),
            .last
        )
    }

    func testUsesNegotiatedEndOfDataBitInsteadOfHardCodingBitOne() throws {
        let parser = try XCTUnwrap(AppleHEVCSubframeBoundaryParser(
            negotiationDetails: "FLS;EOD:5;"
        ))

        XCTAssertEqual(parser.classify(nalUnits: [slice(controlByte: 0xa0)]), .last)
        XCTAssertEqual(parser.classify(nalUnits: [slice(controlByte: 0x82)]), .notLast)
    }

    func testRemovesEmulationPreventionBytesBeforeReadingControlByte() throws {
        let parser = try makeParser()
        let unit = Data([0x02, 0x01, 0x00, 0x00, 0x03, 0x82])

        XCTAssertEqual(parser.classify(nalUnits: [unit]), .last)
    }

    func testReturnsUnknownForUnsupportedNegotiationAndMalformedAccessUnit() throws {
        XCTAssertNil(AppleHEVCSubframeBoundaryParser(
            negotiationDetails: "LF:-1;EOD:1;"
        ))
        XCTAssertNil(AppleHEVCSubframeBoundaryParser(
            negotiationDetails: "FLS;EOD:8;"
        ))

        let parser = try makeParser()
        XCTAssertEqual(parser.classify(nalUnits: []), .unknown)
        XCTAssertEqual(parser.classify(nalUnits: [Data([0x02, 0x01])]), .unknown)
        XCTAssertEqual(
            parser.classify(nalUnits: [Data([0x42, 0x01, 0x82])]),
            .unknown
        )
    }

    private func makeParser() throws -> AppleHEVCSubframeBoundaryParser {
        try XCTUnwrap(AppleHEVCSubframeBoundaryParser(
            negotiationDetails: "FLS;LF:-1;POS:5;EOD:1;HTS:2;RR:3;POSE:4;"
        ))
    }

    private func slice(controlByte: UInt8) -> Data {
        Data([0x02, 0x01, 0xaa, controlByte])
    }
}
