import XCTest
@testable import iShareScreen

final class AppleEncryptedRecordLayerTests: XCTestCase {
    func testFirstRecordMatchesIndependentReferenceVector() throws {
        let layer = try makeLayer()

        let record = try layer.encrypt(Data("hello".utf8))

        XCTAssertEqual(
            record,
            try XCTUnwrap(Data(hex: "0020c2c84a51efbfeb9a84e3b9e83dd11c2686fb5d7dca66028cf06c37df39959249"))
        )
    }

    func testRoundTripsMultipleRecordsWithChainedIVAndCounters() throws {
        let sender = try makeLayer()
        let receiver = try makeLayer()
        let first = try sender.encrypt(Data([0x02, 0x00]))
        let second = try sender.encrypt(Data([0x1c, 0xaa, 0xbb, 0xcc]))

        XCTAssertEqual(try receiver.decrypt(Data(first.dropFirst(2))), Data([0x02, 0x00]))
        XCTAssertEqual(try receiver.decrypt(Data(second.dropFirst(2))), Data([0x1c, 0xaa, 0xbb, 0xcc]))
    }

    func testEncryptsSelectedDisplayAndPointerAsOneOrderedBatch() throws {
        let sender = try makeLayer()
        let receiver = try makeLayer()
        let messages = [Data([0x0d, 0x01]), Data([0x10, 0x02])]
        var records = try sender.encrypt(messages)

        XCTAssertEqual(try receiver.decryptAvailableRecords(in: &records), messages)
        XCTAssertTrue(records.isEmpty)
    }

    func testStreamingDecoderKeepsIncompleteTail() throws {
        let sender = try makeLayer()
        let receiver = try makeLayer()
        let first = try sender.encrypt(Data("one".utf8))
        let second = try sender.encrypt(Data("two".utf8))
        var buffer = first + second.prefix(9)

        XCTAssertEqual(try receiver.decryptAvailableRecords(in: &buffer), [Data("one".utf8)])
        XCTAssertEqual(buffer, second.prefix(9))

        buffer.append(second.dropFirst(9))
        XCTAssertEqual(try receiver.decryptAvailableRecords(in: &buffer), [Data("two".utf8)])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testRejectsTamperedAuthenticationCodeAndInvalidFrameLength() throws {
        let sender = try makeLayer()
        let receiver = try makeLayer()
        var ciphertext = Data(try sender.encrypt(Data("hello".utf8)).dropFirst(2))
        ciphertext[ciphertext.count - 1] ^= 0x01

        XCTAssertThrowsError(try receiver.decrypt(ciphertext)) { error in
            XCTAssertEqual(error as? AppleEncryptedRecordError, .authenticationFailed)
        }

        var malformed = Data([0x00, 0x11]) + Data(repeating: 0, count: 17)
        XCTAssertThrowsError(try makeLayer().decryptAvailableRecords(in: &malformed))
    }

    private func makeLayer() throws -> AppleEncryptedRecordLayer {
        AppleEncryptedRecordLayer(
            keys: try AppleRecordKeys(
                key: XCTUnwrap(Data(hex: "000102030405060708090a0b0c0d0e0f")),
                initializationVector: XCTUnwrap(Data(hex: "101112131415161718191a1b1c1d1e1f"))
            )
        )
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        self.init()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            append(byte)
            index = next
        }
    }
}
