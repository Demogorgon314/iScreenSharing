import class ScreenSharingProtocol.AppleEncryptedRecordLayer
import struct ScreenSharingProtocol.AppleRecordKeys
import XCTest
@testable import iScreenSharing

final class AppleEncryptedRecordLayerTests: XCTestCase {
    func testSerialWriterPreservesEncryptionAndTransportOrder() async throws {
        let sink = BlockingRecordSink()
        let writer = AppleEncryptedRecordWriter { record in
            await sink.send(record)
        }
        let layer = try makeLayer()
        let expectedLayer = try makeLayer()
        let firstMessages = [
            Data("header".utf8),
            Data("payload-one".utf8),
            Data("payload-two".utf8),
        ]
        let secondMessage = Data("second".utf8)
        let expectedRecords = [
            try expectedLayer.encrypt(firstMessages),
            try expectedLayer.encrypt(secondMessage),
        ]

        let first = Task { try await writer.send(firstMessages, using: layer) }
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

    private func makeLayer() throws -> AppleEncryptedRecordLayer {
        AppleEncryptedRecordLayer(
            keys: try AppleRecordKeys(
                key: Data((0..<16).map(UInt8.init)),
                initializationVector: Data((16..<32).map(UInt8.init))
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
