import Foundation
import XCTest
import ScreenSharingProtocol

final class AppleFileTransferMessageTests: XCTestCase {
    func testBuildsNativeType32GoldenVector() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/type32-oracle-file.txt")
        let message = try AppleFileTransferMessage.beginDrop(
            fileURL: fileURL,
            sessionID: 0x1234
        )

        XCTAssertEqual(message, try XCTUnwrap(Data(hex: """
        20000000000012340000006100000056
        78da62606060646060e02f284dcac94cd64bcbcc49d52d2dca6180009094407
        27eae5e6241414eaa5e7e714965412a508c250da24609a4de4a5f5fbf24b7401
        f24676ca49b5f94980c340424a357525102000000ffff
        """)))
    }

    func testBuildsType32CancelVector() throws {
        XCTAssertEqual(
            try AppleFileTransferMessage.cancelDrop(sessionID: 0x0102_0304),
            try XCTUnwrap(Data(hex: "20000000010203040000000000000000"))
        )
    }

    func testParsesExactType30FileRequestAndRejectsMalformedPaths() throws {
        let valid = try XCTUnwrap(Data(hex: "1e00000000001234000000042f746d70"))
        XCTAssertEqual(
            try AppleFileTransferMessage.fileRequest(from: valid),
            AppleFileTransferRequest(sessionID: 0x1234, destinationPath: "/tmp")
        )

        XCTAssertThrowsError(try AppleFileTransferMessage.fileRequest(from: valid.dropLast()))
        var invalidUTF8 = valid
        invalidUTF8[12] = 0xff
        XCTAssertThrowsError(try AppleFileTransferMessage.fileRequest(from: invalidUTF8))
        var empty = valid.prefix(12)
        empty.writeUInt32BE(0, at: 8)
        XCTAssertThrowsError(try AppleFileTransferMessage.fileRequest(from: empty))
    }

    func testBuildsStartFileReceiveGoldenVector() throws {
        XCTAssertEqual(
            try AppleFileTransferMessage.startFileReceive(
                sessionID: 0x1234,
                destinationPath: "/tmp"
            ),
            try XCTUnwrap(Data(hex: """
            2200000000170001000200001234000000000000000000042f746d7000
            """))
        )
    }

    func testParsesNativeSenderDataAndDoneVectors() throws {
        let dataFrame = try XCTUnwrap(Data(
            hex: "22000000000d00010066000012340000000158"
        ))
        let doneFrame = try XCTUnwrap(Data(
            hex: "22000000000c000100680000123400000000"
        ))

        XCTAssertEqual(
            try AppleFileTransferMessage.senderFrame(
                from: dataFrame,
                expectedSessionID: 0x1234
            ),
            AppleFileCopyFrame(
                command: 102,
                sessionID: 0x1234,
                totalBytes: nil,
                transferredBytes: 1,
                isDone: false,
                status: nil
            )
        )
        XCTAssertEqual(
            try AppleFileTransferMessage.senderFrame(
                from: doneFrame,
                expectedSessionID: 0x1234
            ).status,
            0
        )
        var failedDone = doneFrame
        failedDone.replaceSubrange((failedDone.count - 4)..<failedDone.count, with: [0x78, 0xec, 0xff, 0xff])
        XCTAssertEqual(
            try AppleFileTransferMessage.senderFrame(
                from: failedDone,
                expectedSessionID: 0x1234
            ).status,
            -5_000
        )
        XCTAssertThrowsError(try AppleFileTransferMessage.senderFrame(
            from: dataFrame,
            expectedSessionID: 0x4321
        ))
    }

    func testParsesNativeSenderMetadataVectors() throws {
        let summary = try XCTUnwrap(Data(hex:
            "22000000003c000100640000123400000001000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000"
        ))
        let item = try XCTUnwrap(Data(hex: """
        2200000000ba000100650000123401000000000000000000000000000000000000
        000000000000000000000000000000000000000000000000000000000000000000
        e6b435e6ef060000e6b435e6ef060000e6b4364d6bb10000e6b435e6ef060000
        0000000000000000000081a40000007e00050000612e7478740065787431000000
        0100440000003a000000010000001500000015636f6d2e6170706c652e71756172
        616e74696e6500303038333b30303030303030303b5361666172693b
        """))

        let parsedSummary = try AppleFileTransferMessage.senderFrame(
            from: summary,
            expectedSessionID: 0x1234
        )
        let parsedItem = try AppleFileTransferMessage.senderFrame(
            from: item,
            expectedSessionID: 0x1234
        )

        XCTAssertEqual(parsedSummary.command, 100)
        XCTAssertEqual(parsedSummary.totalBytes, 0)
        XCTAssertEqual(parsedItem.command, 101)
        XCTAssertNil(parsedItem.totalBytes)
    }

    func testParsesNativeToolItemInfoWithMixedByteOrder() throws {
        let itemInfo = try XCTUnwrap(Data(hex: """
        22003c0000000001006400001234000000000000000000350c00000000000040
        0c00000000000100000000000000000000000000000000000000000000000000
        0000
        """))

        let parsed = try AppleFileTransferMessage.senderItemInfo(
            from: itemInfo,
            expectedSessionID: 0x1234
        )

        XCTAssertEqual(parsed.command, 100)
        XCTAssertEqual(parsed.totalBytes, 800_000)
        XCTAssertThrowsError(try AppleFileTransferMessage.senderItemInfo(
            from: itemInfo,
            expectedSessionID: 0x4321
        ))
    }

    func testParsesNativeCompressedDataVector() throws {
        let compressed = try XCTUnwrap(Data(hex: """
        22000000012e00010067000012340001000100000000011c78daecd8bb15824014
        45d1dc2a5e05566303a020e067046714a81e7a3031d8e15d6b47373cb96be25e
        ad4b5cd2f518a77d8da53fdfa29ed2f7196d9a63288fd73bd2a79922c3300cff
        293eb80386611886611886611886611886a540dfc1300cc3300cc3300cc3300cc3
        b01408c3300cc3300cc3300cc3300cc3b01408c3300cc3300cc3300cc3300cc3
        b01408c3300cc3300cc3300cc3300cc3b01408c3300cc3300cc3300cc3300cc3
        b01408c3300cc3300cc3300cc3300cc3b01408c3300cc3300cc3300cc3300cc3
        b01408c3300cc3300cc3300cc3300cc352a03b601886611886611886611886615
        80af41d0cc3300cc3300cc3300cc3300c4b81300cc3300cc3300cc3300cc3300
        c4b81300cc3300cc330fc2bde000000ffff
        """))

        let frame = try AppleFileTransferMessage.senderFrame(
            from: compressed,
            expectedSessionID: 0x1234
        )

        XCTAssertEqual(frame.command, 103)
        XCTAssertEqual(frame.transferredBytes, 65_536)
    }

    func testParsesCompletionAndProgressResponses() throws {
        let completion = try XCTUnwrap(Data(
            hex: "220000000012000100c80000123400000005622e62696e00"
        ))
        let progress = try XCTUnwrap(Data(
            hex: "2200000000100001012c000012343fe0000000000000"
        ))

        XCTAssertEqual(
            try AppleFileTransferMessage.response(from: completion),
            .completed(sessionID: 0x1234, errorCode: 0, name: "b.bin")
        )
        XCTAssertEqual(
            try AppleFileTransferMessage.response(from: progress),
            .progress(sessionID: 0x1234, fraction: 0.5)
        )

        var producerDefinedProgress = progress
        producerDefinedProgress.replaceSubrange(
            (producerDefinedProgress.count - 8)..<producerDefinedProgress.count,
            with: try XCTUnwrap(Data(hex: "3ff8000000000000"))
        )
        XCTAssertEqual(
            try AppleFileTransferMessage.response(from: producerDefinedProgress),
            .progress(sessionID: 0x1234, fraction: 1.5)
        )
    }

    func testReassemblesNativeToolIPCIncrementally() throws {
        let frame = try XCTUnwrap(Data(
            hex: "22000000000d00010066000012340000000158"
        ))
        var stream = Data()
        stream.appendUInt32LE(UInt32(frame.count + 2))
        stream.appendUInt16LE(1)
        stream.append(frame)
        stream.appendUInt32LE(4)
        stream.appendUInt16LE(2)
        stream.appendUInt16LE(0)
        var parser = AppleFileCopyToolMessageParser()

        XCTAssertTrue(try parser.process(stream.prefix(7)).isEmpty)
        XCTAssertEqual(
            try parser.process(stream.dropFirst(7)),
            [.frame(frame), .finished(status: 0)]
        )
        XCTAssertNoThrow(try parser.finish())
    }

    func testFragmentsFileDataWithoutExceedingEncryptedRecordLimit() {
        let message = Data(repeating: 1, count: 130_001)

        let fragments = AppleFileTransferMessage.fragments(of: message)

        XCTAssertEqual(fragments.map(\.count), [60_000, 60_000, 10_001])
        XCTAssertEqual(fragments.reduce(into: Data()) { $0.append($1) }, message)
    }
}

private extension Data {
    init?(hex: String) {
        let compact = hex.filter { !$0.isWhitespace }
        guard compact.count.isMultiple(of: 2) else { return nil }
        self.init()
        reserveCapacity(compact.count / 2)
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<next], radix: 16) else { return nil }
            append(byte)
            index = next
        }
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    mutating func writeUInt32BE(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value >> 24)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        self[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 3] = UInt8(truncatingIfNeeded: value)
    }
}
