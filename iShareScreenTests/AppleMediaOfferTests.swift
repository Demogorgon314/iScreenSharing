import CryptoKit
import XCTest
@testable import iShareScreen

final class AppleMediaOfferTests: XCTestCase {
    func testVideoDecoderNegotiationIncludesAlternateTilePositionControl() {
        XCTAssertTrue(AppleMediaOffer.videoDecoderNegotiationDetails.contains("POS:5"))
        XCTAssertTrue(AppleMediaOffer.videoDecoderNegotiationDetails.contains("POSE:4"))
        XCTAssertTrue(AppleMediaOffer.videoDecoderNegotiationDetails.contains("EOD:1"))
    }

    func testCreatesBinaryVideoAndAudioOffers() throws {
        var randomValues: [UInt32] = [0x1122_3344, 0x5566_7788]
        let fixedUUID = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let offers = try AppleMediaOffer.create(
            randomUInt32: { randomValues.removeFirst() },
            timestamp: { 123_456_789 },
            uuid: { fixedUUID }
        )
        XCTAssertEqual(offers.videoSynchronizationSource, 0x1122_3344)
        XCTAssertEqual(offers.audioSynchronizationSource, 0x5566_7788)

        for (offer, mode) in [(offers.video, 7), (offers.audio, 8)] {
            XCTAssertEqual(String(data: offer.prefix(8), encoding: .ascii), "bplist00")
            let value = try PropertyListSerialization.propertyList(from: offer, format: nil)
            let dictionary = try XCTUnwrap(value as? [String: Any])
            XCTAssertEqual(dictionary["avcMediaStreamNegotiatorMode"] as? Int, mode)
            XCTAssertEqual(
                dictionary["avcMediaStreamOptionCallID"] as? String,
                fixedUUID.uuidString.uppercased()
            )
            XCTAssertFalse(try AppleMediaOffer.decompressMediaBlob(from: offer).isEmpty)
        }
        XCTAssertEqual(
            SHA256.hash(data: try AppleMediaOffer.decompressMediaBlob(from: offers.video)).hex,
            "e39b757ea49401b1fd22de635fb84df9f5bc3b2fc70f838415bb561bc27522ef"
        )
        XCTAssertEqual(
            SHA256.hash(data: try AppleMediaOffer.decompressMediaBlob(from: offers.audio)).hex,
            "a588683538adaf6f29b1bb37e5552829c2d4012dd7f302af3a1b33336af7e3bf"
        )
    }

    func testDisablingAudioChangesAudioOffer() throws {
        let enabled = try AppleMediaOffer.create(
            audioEnabled: true,
            randomUInt32: { 1 },
            timestamp: { 2 },
            uuid: { UUID() }
        )
        let disabled = try AppleMediaOffer.create(
            audioEnabled: false,
            randomUInt32: { 1 },
            timestamp: { 2 },
            uuid: { UUID() }
        )

        XCTAssertNotEqual(
            try AppleMediaOffer.decompressMediaBlob(from: enabled.audio),
            try AppleMediaOffer.decompressMediaBlob(from: disabled.audio)
        )
    }
}

private extension SHA256.Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
