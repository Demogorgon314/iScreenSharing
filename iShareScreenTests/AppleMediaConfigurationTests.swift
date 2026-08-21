import XCTest
@testable import iShareScreen

final class AppleMediaConfigurationTests: XCTestCase {
    func testBuildsExpectedWireLayout() throws {
        let audio = Data([0xa1, 0xa2, 0xa3])
        let video = Data([0xb1, 0xb2])
        let keys = AppleMediaKeys(
            audioViewer: Data(repeating: 0x11, count: 46),
            audioServer: Data(repeating: 0x22, count: 46),
            videoViewer: Data(repeating: 0x33, count: 46),
            videoServer: Data(repeating: 0x44, count: 46)
        )
        let callID = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!

        let message = try AppleMediaConfiguration.message(
            audioOffer: audio,
            videoOffer: video,
            keys: keys,
            callID: callID
        )

        XCTAssertEqual(message.count, 0xd8 + audio.count + video.count + 4)
        XCTAssertEqual(message[0], 0x1c)
        XCTAssertEqual(try message.uint16BE(at: 2), UInt16(message.count - 4))
        XCTAssertEqual(try message.uint16BE(at: 4), 3)
        XCTAssertEqual(message[6..<10], Data([0x05, 0, 0, 0]))
        XCTAssertEqual(try message.uint16BE(at: 10), 3)
        XCTAssertEqual(try message.uint16BE(at: 12), 2)
        XCTAssertEqual(try message.uint16BE(at: 14), 0)
        XCTAssertEqual(
            message.subdata(in: 0x14..<0x24),
            Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                  0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
        )
        XCTAssertEqual(message.subdata(in: 0x24..<0x52), keys.audioViewer)
        XCTAssertEqual(message.subdata(in: 0x52..<0x80), keys.audioServer)
        XCTAssertEqual(message.subdata(in: 0x80..<0x83), audio)
        XCTAssertEqual(message.subdata(in: 0x83..<0xb1), keys.videoViewer)
        XCTAssertEqual(message.subdata(in: 0xb1..<0xdf), keys.videoServer)
        XCTAssertEqual(message.suffix(video.count), video)
    }

    func testBuildsSecondVideoStreamWithIndependentKeys() throws {
        let keys = AppleMediaKeys(
            audioViewer: Data(repeating: 0x11, count: 46),
            audioServer: Data(repeating: 0x22, count: 46),
            videoViewer: Data(repeating: 0x33, count: 46),
            videoServer: Data(repeating: 0x44, count: 46),
            secondaryVideoViewer: Data(repeating: 0x55, count: 46),
            secondaryVideoServer: Data(repeating: 0x66, count: 46)
        )
        let message = try AppleMediaConfiguration.message(
            audioOffer: Data([0xa1]),
            videoOffer: Data([0xb1, 0xb2]),
            secondaryVideoOffer: Data([0xc1, 0xc2, 0xc3]),
            keys: keys
        )
        XCTAssertEqual(message[6..<10], Data([0x07, 0, 0, 0]))
        XCTAssertEqual(try message.uint16BE(at: 14), 3)
        XCTAssertEqual(message.suffix(3), Data([0xc1, 0xc2, 0xc3]))
    }

    func testRejectsInvalidKeyLength() {
        let keys = AppleMediaKeys(
            audioViewer: Data(),
            audioServer: Data(repeating: 0, count: 46),
            videoViewer: Data(repeating: 0, count: 46),
            videoServer: Data(repeating: 0, count: 46)
        )
        XCTAssertThrowsError(
            try AppleMediaConfiguration.message(audioOffer: Data(), videoOffer: Data(), keys: keys)
        ) { error in
            XCTAssertEqual(error as? AppleMediaConfigurationError, .invalidKeyLength)
        }
    }

    func testExtractsCanvasFromEmbeddedVideoAnswerPropertyList() throws {
        let fixture = try XCTUnwrap(Data(
            base64Encoded: "AHByZWZpeGJwbGlzdDAw0QECXxAhYXZjTWVkaWFTdHJlYW1OZWdvdGlhdG9yTWVkaWFCbG9iTxASeJzT4lBo4NfYwWHAAgAK9AH+CAsvAAAAAAAAAQEAAAAAAAAAAwAAAAAAAAAAAAAAAAAAAER0YWls"
        ))

        XCTAssertEqual(
            AppleMediaConfiguration.canvas(from: fixture),
            AppleCanvas(width: 1920, height: 1080, tileCount: 4)
        )
        XCTAssertEqual(
            AppleMediaConfiguration.answerStatus(from: fixture),
            .canvas(AppleCanvas(width: 1920, height: 1080, tileCount: 4))
        )
    }

    func testDistinguishesUnrelatedControlMessagesFromDegenerateMediaAnswers() throws {
        XCTAssertEqual(
            AppleMediaConfiguration.answerStatus(from: Data([0, 1, 2, 3])),
            .unrelated
        )

        let propertyList = try PropertyListSerialization.data(
            fromPropertyList: [
                "avcMediaStreamNegotiatorMediaBlob": try ZlibCodec.compress(Data([0x08, 0x01])),
            ],
            format: .binary,
            options: 0
        )
        XCTAssertEqual(
            AppleMediaConfiguration.answerStatus(from: Data([0]) + propertyList),
            .degenerate
        )
    }
}
