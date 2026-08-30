import CryptoKit
import Foundation
import XCTest
@testable import ScreenSharingProtocol

final class AppleEncryptedRecordLayerTests: XCTestCase {
    func testFirstRecordMatchesIndependentReferenceVector() throws {
        let record = try makeLayer().encrypt(Data("hello".utf8))

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

        XCTAssertEqual(try receiver.decrypt(ciphertext(from: first)), Data([0x02, 0x00]))
        XCTAssertEqual(
            try receiver.decrypt(ciphertext(from: second)),
            Data([0x1c, 0xaa, 0xbb, 0xcc])
        )
    }

    func testEncryptsMessagesAsOneOrderedBatch() throws {
        let messages = [Data([0x0d, 0x01]), Data([0x10, 0x02])]
        let batchedRecords = try makeLayer().encrypt(messages)
        let sequentialSender = try makeLayer()
        var sequentialRecords = Data()
        for message in messages {
            sequentialRecords.append(try sequentialSender.encrypt(message))
        }

        XCTAssertEqual(batchedRecords, sequentialRecords)
    }

    func testFileCopyFrameSpansRecordsAsOneContinuousMessage() throws {
        var body = Data()
        BigEndianWire.append(UInt16(1), to: &body)
        BigEndianWire.append(UInt16(102), to: &body)
        BigEndianWire.append(UInt32(0x1234), to: &body)
        BigEndianWire.append(UInt32(65_536), to: &body)
        body.append(Data(repeating: 0x58, count: 65_536))
        var message = Data([0x22, 0])
        BigEndianWire.append(UInt32(body.count), to: &message)
        message.append(body)

        let fragments = AppleFileTransferMessage.fragments(of: message)
        XCTAssertEqual(fragments.map(\.count), [60_000, 5_554])

        let sender = try makeLayer()
        let receiver = try makeLayer()
        let records = try sender.encrypt(fragments)
        var offset = 0
        var reassembled = Data()
        while offset < records.count {
            let ciphertextLength = try Int(XCTUnwrap(
                BigEndianWire.uint16(from: records, at: offset)
            ))
            let ciphertextStart = offset + 2
            let ciphertextEnd = ciphertextStart + ciphertextLength
            reassembled.append(try receiver.decrypt(
                records.subdata(in: ciphertextStart..<ciphertextEnd)
            ))
            offset = ciphertextEnd
        }

        XCTAssertEqual(reassembled, message)
        let parsed = try AppleFileTransferMessage.senderFrame(
            from: reassembled,
            expectedSessionID: 0x1234
        )
        XCTAssertEqual(parsed.command, 102)
        XCTAssertEqual(parsed.transferredBytes, 65_536)
    }

    func testAuthenticationFailureAdvancesChainAndAllowsNextRecord() throws {
        let sender = try makeLayer()
        let receiver = try makeLayer()
        var firstCiphertext = ciphertext(from: try sender.encrypt(Data("first".utf8)))
        let secondCiphertext = ciphertext(from: try sender.encrypt(Data("second".utf8)))
        firstCiphertext[0] ^= 0x01

        XCTAssertThrowsError(try receiver.decrypt(firstCiphertext)) { error in
            XCTAssertEqual(error as? AppleEncryptedRecordError, .authenticationFailed)
        }
        XCTAssertEqual(try receiver.decrypt(secondCiphertext), Data("second".utf8))
    }

    func testCountersWrapWithoutBreakingChainedRecords() throws {
        let keys = try makeKeys()
        let sender = AppleEncryptedRecordLayer(
            keys: keys,
            sendCounter: .max,
            receiveCounter: 0
        )
        let receiver = AppleEncryptedRecordLayer(
            keys: keys,
            sendCounter: 0,
            receiveCounter: .max
        )

        let lastCounterRecord = try sender.encrypt(Data("last".utf8))
        let wrappedCounterRecord = try sender.encrypt(Data("wrapped".utf8))

        XCTAssertEqual(
            try receiver.decrypt(ciphertext(from: lastCounterRecord)),
            Data("last".utf8)
        )
        XCTAssertEqual(
            try receiver.decrypt(ciphertext(from: wrappedCounterRecord)),
            Data("wrapped".utf8)
        )
    }

    func testReceiveCounterWindowAcceptsFiveAheadAndOneBehindOnly() throws {
        let keys = try makeKeys()
        let fiveAhead = AppleEncryptedRecordLayer(
            keys: keys,
            sendCounter: 5,
            receiveCounter: 0
        )
        XCTAssertEqual(
            try AppleEncryptedRecordLayer(keys: keys).decrypt(
                ciphertext(from: try fiveAhead.encrypt(Data("ahead".utf8)))
            ),
            Data("ahead".utf8)
        )

        let oneBehind = AppleEncryptedRecordLayer(
            keys: keys,
            sendCounter: 5,
            receiveCounter: 0
        )
        let receiver = AppleEncryptedRecordLayer(
            keys: keys,
            sendCounter: 0,
            receiveCounter: 6
        )
        XCTAssertEqual(
            try receiver.decrypt(ciphertext(from: try oneBehind.encrypt(Data("behind".utf8)))),
            Data("behind".utf8)
        )

        let outsideWindow = AppleEncryptedRecordLayer(
            keys: keys,
            sendCounter: 6,
            receiveCounter: 0
        )
        XCTAssertThrowsError(try AppleEncryptedRecordLayer(keys: keys).decrypt(
            ciphertext(from: try outsideWindow.encrypt(Data("outside".utf8)))
        )) {
            XCTAssertEqual($0 as? AppleEncryptedRecordError, .authenticationFailed)
        }

        let twoBehind = AppleEncryptedRecordLayer(
            keys: keys,
            sendCounter: 4,
            receiveCounter: 0
        )
        let pastWindowReceiver = AppleEncryptedRecordLayer(
            keys: keys,
            sendCounter: 0,
            receiveCounter: 6
        )
        let tooOldCiphertext = ciphertext(from: try twoBehind.encrypt(Data("too-old".utf8)))
        XCTAssertThrowsError(try pastWindowReceiver.decrypt(tooOldCiphertext)) {
            XCTAssertEqual($0 as? AppleEncryptedRecordError, .authenticationFailed)
        }
    }

    func testRejectsOversizedMessagesAndMalformedCiphertext() throws {
        let sender = try makeLayer()
        XCTAssertThrowsError(try sender.encrypt([
            Data("discarded".utf8),
            Data(count: 65_535),
        ])) { error in
            XCTAssertEqual(error as? AppleEncryptedRecordError, .messageTooLarge)
        }
        XCTAssertEqual(
            try sender.encrypt(Data("first".utf8)),
            try makeLayer().encrypt(Data("first".utf8))
        )
        XCTAssertThrowsError(try makeLayer().decrypt(Data(repeating: 0, count: 17))) { error in
            XCTAssertEqual(error as? AppleEncryptedRecordError, .invalidCiphertext)
        }
    }

    func testRejectsAuthenticatedBodyWithInvalidMessageLength() throws {
        let keys = try makeKeys()
        var body = Data([0xff, 0xff])
        body.append(Data(repeating: 0, count: 10))
        var digestInput = Data()
        BigEndianWire.append(UInt32(0), to: &digestInput)
        digestInput.append(body)
        body.append(Data(Insecure.SHA1.hash(data: digestInput)))
        let ciphertext = try AppleProtocolAES.encryptCBC(
            body,
            key: keys.key,
            initializationVector: keys.initializationVector
        )

        XCTAssertThrowsError(try AppleEncryptedRecordLayer(keys: keys).decrypt(ciphertext)) {
            XCTAssertEqual($0 as? AppleEncryptedRecordError, .invalidPlaintext)
        }
    }

    func testRekeyUnwrapsContentKeyAndRejectsInvalidInputs() throws {
        let wrappingKey = Data(repeating: 0x11, count: 16)
        let contentKey = Data((0..<16).map(UInt8.init))
        let initializationVector = Data((16..<32).map(UInt8.init))
        var payload = Data()
        BigEndianWire.append(UInt32(7), to: &payload)
        payload.append(try AppleProtocolAES.encryptECB(contentKey, key: wrappingKey))
        payload.append(try AppleProtocolAES.encryptECB(
            initializationVector,
            key: wrappingKey
        ))

        let keys = try AppleRekey(payload: payload).unwrap(using: wrappingKey)

        XCTAssertEqual(keys.key, contentKey)
        XCTAssertEqual(keys.initializationVector, initializationVector)
        XCTAssertThrowsError(try AppleRekey(payload: payload).unwrap(using: Data())) {
            XCTAssertEqual($0 as? AppleRecordKeyError, .decryptionFailed)
        }
        XCTAssertThrowsError(try AppleRecordKeys(
            key: contentKey.dropLast(),
            initializationVector: initializationVector
        )) {
            XCTAssertEqual($0 as? AppleRecordKeyError, .invalidLength)
        }
    }

    private func makeLayer() throws -> AppleEncryptedRecordLayer {
        AppleEncryptedRecordLayer(keys: try makeKeys())
    }

    private func makeKeys() throws -> AppleRecordKeys {
        try AppleRecordKeys(
            key: XCTUnwrap(Data(hex: "000102030405060708090a0b0c0d0e0f")),
            initializationVector: XCTUnwrap(Data(hex: "101112131415161718191a1b1c1d1e1f"))
        )
    }

    private func ciphertext(from record: Data) -> Data {
        Data(record.dropFirst(2))
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
