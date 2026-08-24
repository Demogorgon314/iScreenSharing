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
        let messages = [Data([0x0d, 0x01]), Data([0x10, 0x02])]
        let batchedRecords = try makeLayer().encrypt(messages)
        let sequentialSender = try makeLayer()
        var sequentialRecords = Data()
        for message in messages {
            sequentialRecords.append(try sequentialSender.encrypt(message))
        }

        XCTAssertEqual(batchedRecords, sequentialRecords)
    }

    func testSerialWriterPreservesEncryptionAndTransportOrder() async throws {
        let sink = BlockingRecordSink()
        let writer = AppleEncryptedRecordWriter { record in
            await sink.send(record)
        }
        let layer = try makeLayer()
        let expectedLayer = try makeLayer()
        let firstMessage = Data("first".utf8)
        let secondMessage = Data("second".utf8)
        let expectedRecords = [
            try expectedLayer.encrypt(firstMessage),
            try expectedLayer.encrypt(secondMessage),
        ]

        let first = Task { try await writer.send([firstMessage], using: layer) }
        await sink.waitForFirstRecord()
        let second = Task { try await writer.send([secondMessage], using: layer) }
        for _ in 0..<20 { await Task.yield() }

        let blockedRecordCount = await sink.recordCount
        XCTAssertEqual(blockedRecordCount, 1)
        await sink.releaseFirstRecord()
        try await first.value
        try await second.value
        let records = await sink.records
        XCTAssertEqual(records, expectedRecords)
    }

    func testSerialWriterStopsAfterTransportFailureAdvancesCipherState() async throws {
        let sink = FailingRecordSink()
        let writer = AppleEncryptedRecordWriter { record in
            try await sink.send(record)
        }
        let layer = try makeLayer()

        do {
            try await writer.send([Data("first".utf8)], using: layer)
            XCTFail("The failing transport should reject the first record")
        } catch {
            XCTAssertEqual(error as? RecordSinkError, .failed)
        }
        do {
            try await writer.send([Data("second".utf8)], using: layer)
            XCTFail("The writer must remain failed after advancing the CBC chain")
        } catch {
            XCTAssertEqual(error as? AppleEncryptedRecordWriterError, .transportFailed)
        }
        let attempts = await sink.attempts
        XCTAssertEqual(attempts, 1)
    }

    func testRejectsTamperedAuthenticationCodeAndInvalidFrameLength() throws {
        let sender = try makeLayer()
        let receiver = try makeLayer()
        var ciphertext = Data(try sender.encrypt(Data("hello".utf8)).dropFirst(2))
        ciphertext[ciphertext.count - 1] ^= 0x01

        XCTAssertThrowsError(try receiver.decrypt(ciphertext)) { error in
            XCTAssertEqual(error as? AppleEncryptedRecordError, .authenticationFailed)
        }

        XCTAssertThrowsError(try makeLayer().decrypt(Data(repeating: 0, count: 17))) { error in
            XCTAssertEqual(error as? AppleEncryptedRecordError, .invalidCiphertext)
        }
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

private enum RecordSinkError: Error {
    case failed
}

private actor FailingRecordSink {
    private(set) var attempts = 0

    func send(_ record: Data) throws {
        _ = record
        attempts += 1
        throw RecordSinkError.failed
    }
}

private actor BlockingRecordSink {
    private(set) var records = [Data]()
    private var firstRecordContinuation: CheckedContinuation<Void, Never>?

    var recordCount: Int { records.count }

    func send(_ record: Data) async {
        records.append(record)
        guard records.count == 1 else { return }
        await withCheckedContinuation { continuation in
            firstRecordContinuation = continuation
        }
    }

    func waitForFirstRecord() async {
        while records.isEmpty { await Task.yield() }
    }

    func releaseFirstRecord() {
        firstRecordContinuation?.resume()
        firstRecordContinuation = nil
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
