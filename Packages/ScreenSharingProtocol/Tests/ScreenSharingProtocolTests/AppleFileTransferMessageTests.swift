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

    func testBuildsStartFileSendGoldenVector() throws {
        XCTAssertEqual(
            try AppleFileTransferMessage.startFileSend(
                sessionID: 0x1234,
                sourcePath: "/tmp"
            ),
            try XCTUnwrap(Data(hex: """
            2200000000170001000100001234000000010000000000042f746d7000
            """))
        )
    }

    func testBuildsNativePauseContinueAndStopVectors() throws {
        XCTAssertEqual(
            try AppleFileTransferMessage.control(sessionID: 0x1234, action: .pause),
            try XCTUnwrap(Data(hex: "2200000000080001000300001234"))
        )
        XCTAssertEqual(
            try AppleFileTransferMessage.control(sessionID: 0x1234, action: .resume),
            try XCTUnwrap(Data(hex: "2200000000080001000400001234"))
        )
        XCTAssertEqual(
            try AppleFileTransferMessage.control(sessionID: 0x1234, action: .stop),
            try XCTUnwrap(Data(hex: "2200000000080001000500001234"))
        )
    }

    func testBuildsNativeCompletionAndProgressVectors() throws {
        XCTAssertEqual(
            try AppleFileTransferMessage.completion(
                sessionID: 0x1234,
                errorCode: 0,
                name: "b.bin"
            ),
            try XCTUnwrap(Data(hex: "220000000012000100c80000123400000005622e62696e00"))
        )
        XCTAssertEqual(
            try AppleFileTransferMessage.progress(sessionID: 0x1234, fraction: 0.5),
            try XCTUnwrap(Data(hex: "2200000000100001012c000012343fe0000000000000"))
        )
        XCTAssertEqual(
            try AppleFileTransferMessage.completion(
                sessionID: 0x1234,
                errorCode: 5,
                name: ""
            ),
            try XCTUnwrap(Data(hex: "22000000000d000100c8000012340005000000"))
        )
    }

    func testBuildsNativeSenderSummaryDataItemAndDoneVectors() throws {
        XCTAssertEqual(
            try AppleFileTransferMessage.senderSummary(
                sessionID: 0x1234,
                summary: AppleFileCopySummary(
                    rootIsFile: true,
                    logicalBytes: 1,
                    physicalBytes: 4_096,
                    fileCount: 1,
                    folderCount: 0
                )
            ),
            try XCTUnwrap(Data(hex: "22000000003c000100640000123400000001000000000000000000000001000000000000100000000000000000010000000000000000000000000000000000000000"))
        )
        XCTAssertEqual(
            try AppleFileTransferMessage.senderItem(
                sessionID: 0x1234,
                item: AppleFileCopyItemMetadata(
                    type: .file,
                    finderInfo: Data(repeating: 0, count: 32),
                    resourceForkSize: 0,
                    dataForkSize: 1,
                    creationDate: .zero,
                    contentModificationDate: .zero,
                    attributeModificationDate: .zero,
                    accessDate: .zero,
                    nodeFlags: 0,
                    level: 0,
                    mode: 0o100644,
                    textEncodingHint: 0x7e,
                    name: "a"
                )
            ),
            try XCTUnwrap(Data(hex: "22000000007200010065000012340100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000081a40000007e000100006100"))
        )
        XCTAssertEqual(
            try AppleFileTransferMessage.senderData(
                sessionID: 0x1234,
                data: Data([0x58])
            ),
            try XCTUnwrap(Data(hex: "22000000000d00010066000012340000000158"))
        )
        XCTAssertEqual(
            try AppleFileTransferMessage.senderDone(sessionID: 0x1234, status: -5_000),
            try XCTUnwrap(Data(hex: "22000000000c000100680000123478ecffff"))
        )
    }

    func testBuildsNativeToolItemInfoMixedEndianVector() throws {
        XCTAssertEqual(
            try AppleFileTransferMessage.senderItemInfo(
                sessionID: 0x1234,
                summary: AppleFileCopySummary(
                    rootIsFile: true,
                    logicalBytes: 800_000,
                    physicalBytes: 802_816,
                    fileCount: 1,
                    folderCount: 0
                )
            ),
            try XCTUnwrap(Data(hex: """
            22003c0000000001006400001234000000000000000000350c00000000000040
            0c00000000000100000000000000000000000000000000000000000000000000
            0000
            """))
        )
    }

    func testSenderItemPreservesNativeExtendedFinderInfoQuirk() throws {
        var finderInfo = Data(repeating: 0, count: 32)
        finderInfo[24] = 0x12
        finderInfo[25] = 0x34
        let message = try AppleFileTransferMessage.senderItem(
            sessionID: 1,
            item: AppleFileCopyItemMetadata(
                type: .file,
                finderInfo: finderInfo,
                resourceForkSize: 0,
                dataForkSize: 0,
                creationDate: .zero,
                contentModificationDate: .zero,
                attributeModificationDate: .zero,
                accessDate: .zero,
                nodeFlags: 0,
                level: 0,
                mode: 0o100600,
                textEncodingHint: 0x7e,
                name: "file"
            )
        )

        XCTAssertEqual(message.subdata(in: 40..<42), Data([0x34, 0x12]))
    }

    func testSenderItemGroupsExtendedAttributeHeadersBeforePayloads() throws {
        let message = try AppleFileTransferMessage.senderItem(
            sessionID: 1,
            item: AppleFileCopyItemMetadata(
                type: .file,
                finderInfo: Data(repeating: 0, count: 32),
                resourceForkSize: 0,
                dataForkSize: 0,
                creationDate: .zero,
                contentModificationDate: .zero,
                attributeModificationDate: .zero,
                accessDate: .zero,
                nodeFlags: 0,
                level: 0,
                mode: 0o100600,
                textEncodingHint: 0x7e,
                name: "file",
                extendedAttributes: [
                    AppleFileCopyExtendedAttribute(name: "a", value: Data([1])),
                    AppleFileCopyExtendedAttribute(name: "bc", value: Data([2, 3])),
                ]
            )
        )

        XCTAssertEqual(
            message.suffix(42),
            try XCTUnwrap(Data(hex: """
            6578743100000001002a00000020000000020000000200000001000000030000
            00026100016263000203
            """))
        )
    }

    func testRejectsInvalidStartControlAndResponseInputs() {
        XCTAssertThrowsError(try AppleFileTransferMessage.startFileSend(
            sessionID: 0,
            sourcePath: "/tmp"
        ))
        XCTAssertThrowsError(try AppleFileTransferMessage.startFileSend(
            sessionID: 1,
            sourcePath: String(repeating: "a", count: 20_001)
        ))
        XCTAssertThrowsError(try AppleFileTransferMessage.control(
            sessionID: 0,
            action: .stop
        ))
        XCTAssertThrowsError(try AppleFileTransferMessage.completion(
            sessionID: 1,
            errorCode: 4,
            name: "file"
        ))
        XCTAssertThrowsError(try AppleFileTransferMessage.progress(
            sessionID: 1,
            fraction: .nan
        ))
        XCTAssertThrowsError(try AppleFileTransferMessage.progress(
            sessionID: 1,
            fraction: 1.01
        ))
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
        )) {
            XCTAssertEqual($0 as? AppleFileTransferError, .sessionMismatch)
        }
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

    func testParsesDirectoryAndNestedSymbolicLinkSenderFrames() throws {
        let summary = try AppleFileTransferMessage.senderSummary(
            sessionID: 0x1234,
            summary: AppleFileCopySummary(
                rootIsFile: false,
                logicalBytes: 11,
                physicalBytes: 4_096,
                fileCount: 2,
                folderCount: 2
            )
        )
        let directory = try AppleFileTransferMessage.senderItem(
            sessionID: 0x1234,
            item: AppleFileCopyItemMetadata(
                type: .directory,
                finderInfo: Data(repeating: 0, count: 32),
                resourceForkSize: 0,
                dataForkSize: 0,
                creationDate: .zero,
                contentModificationDate: .zero,
                attributeModificationDate: .zero,
                accessDate: .zero,
                nodeFlags: 0x10,
                level: 1,
                mode: 0o040755,
                textEncodingHint: 0x7e,
                name: "nested"
            )
        )
        let link = try AppleFileTransferMessage.senderItem(
            sessionID: 0x1234,
            item: AppleFileCopyItemMetadata(
                type: .symbolicLink,
                finderInfo: Data(repeating: 0, count: 32),
                resourceForkSize: 0,
                dataForkSize: 11,
                creationDate: .zero,
                contentModificationDate: .zero,
                attributeModificationDate: .zero,
                accessDate: .zero,
                nodeFlags: 0,
                level: 2,
                mode: 0o120755,
                textEncodingHint: 0x7e,
                name: "link",
                symbolicLinkTarget: Data("../root.txt".utf8)
            )
        )

        XCTAssertEqual(
            try AppleFileTransferMessage.senderFrame(
                from: summary,
                expectedSessionID: 0x1234
            ).totalBytes,
            11
        )
        XCTAssertEqual(
            try AppleFileTransferMessage.senderFrame(
                from: directory,
                expectedSessionID: 0x1234
            ).command,
            101
        )
        XCTAssertEqual(
            try AppleFileTransferMessage.senderFrame(
                from: link,
                expectedSessionID: 0x1234
            ).command,
            101
        )
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

        var invalidCommand = Data()
        invalidCommand.appendUInt32LE(2)
        invalidCommand.appendUInt16LE(9)
        var invalidParser = AppleFileCopyToolMessageParser()
        XCTAssertThrowsError(try invalidParser.process(invalidCommand)) {
            XCTAssertEqual($0 as? AppleFileTransferError, .invalidToolOutput)
        }
    }

    func testFragmentsFileDataWithoutExceedingEncryptedRecordLimit() {
        let message = Data(repeating: 1, count: 130_001)

        let fragments = AppleFileTransferMessage.fragments(of: message)

        XCTAssertEqual(fragments.map(\.count), [60_000, 60_000, 10_001])
        XCTAssertEqual(fragments.reduce(into: Data()) { $0.append($1) }, message)
    }

    func testParsesReceiverFramesIncludingMetadataAndExtendedAttributes() throws {
        var finderInfo = Data(repeating: 0, count: 32)
        finderInfo[0] = 0x54
        finderInfo[24] = 0x12
        finderInfo[25] = 0x34
        let metadata = AppleFileCopyItemMetadata(
            type: .file,
            userAccess: 7,
            finderInfo: finderInfo,
            resourceForkSize: 3,
            dataForkSize: 4,
            creationDate: AppleFileCopyUTCDateTime(seconds: 10, fraction: 11),
            contentModificationDate: AppleFileCopyUTCDateTime(seconds: 12, fraction: 13),
            attributeModificationDate: AppleFileCopyUTCDateTime(seconds: 14, fraction: 15),
            accessDate: AppleFileCopyUTCDateTime(seconds: 16, fraction: 17),
            backupDate: AppleFileCopyUTCDateTime(seconds: 18, fraction: 19),
            nodeFlags: 1,
            level: 2,
            mode: 0o100640,
            textEncodingHint: 0x7e,
            name: "file.bin",
            extendedAttributes: [
                AppleFileCopyExtendedAttribute(name: "a", value: Data([1, 2])),
                AppleFileCopyExtendedAttribute(name: "bc", value: Data([3])),
            ]
        )
        let message = try AppleFileTransferMessage.senderItem(sessionID: 0x1234, item: metadata)

        let parsed = try AppleFileTransferMessage.receiverFrame(from: message)

        guard case .item(let item) = parsed.payload else {
            return XCTFail("Expected an item frame")
        }
        XCTAssertEqual(parsed.sessionID, 0x1234)
        XCTAssertEqual(item.type, .file)
        XCTAssertEqual(item.name, "file.bin")
        XCTAssertEqual(item.level, 2)
        XCTAssertEqual(item.dataForkSize, 4)
        XCTAssertEqual(item.resourceForkSize, 3)
        XCTAssertEqual(item.creationDate, metadata.creationDate)
        XCTAssertEqual(item.extendedAttributes, metadata.extendedAttributes)
        XCTAssertEqual(item.finderInfo[0], 0x54)
        XCTAssertEqual(item.finderInfo[24], 0)
        XCTAssertEqual(item.finderInfo[25], 0)
    }

    func testRejectsCompressedReceiverFrameBeyondNativeExpansionBound() throws {
        let uncompressedLength = 1
        let maximumCompressedLength = uncompressedLength
            + uncompressedLength / 16_384
            + 10_038
        var body = Data()
        body.appendUInt16BE(1)
        body.appendUInt16BE(103)
        body.appendUInt32BE(0x1234)
        body.appendUInt16BE(1)
        body.appendUInt32BE(UInt32(uncompressedLength))
        body.appendUInt32BE(UInt32(maximumCompressedLength + 1))
        body.append(Data(repeating: 0, count: maximumCompressedLength + 1))
        var message = Data([0x22, 0])
        message.appendUInt32BE(UInt32(body.count))
        message.append(body)

        XCTAssertThrowsError(try AppleFileTransferMessage.receiverFrame(from: message))
    }

    func testParsesRemoteFileDragArchiveAndEmptyClear() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/remote file.txt")
        let archive = AppleClipboardArchive(items: [
            AppleClipboardItem(flavors: [
                AppleClipboardFlavor(
                    type: "public.file-url",
                    aliases: [
                        AppleClipboardTypeAlias(
                            tagClass: "com.apple.ostype",
                            preferredTag: "furl"
                        )
                    ],
                    value: Data(fileURL.absoluteString.utf8)
                ),
                AppleClipboardFlavor(
                    type: "com.apple.remotedesktop.dragimage-png",
                    aliases: [],
                    value: Data([0x89, 0x50, 0x4e, 0x47])
                ),
            ])
        ])
        var message = try AppleClipboardMessage.send(
            archive: archive,
            sessionID: 0x1234
        )
        message[0] = 0x20

        XCTAssertEqual(
            try AppleFileTransferMessage.remoteDrag(from: message),
            AppleRemoteFileDrag(
                sessionID: 0x1234,
                sourcePaths: [fileURL.path],
                imagePNG: Data([0x89, 0x50, 0x4e, 0x47])
            )
        )
        XCTAssertNil(try AppleFileTransferMessage.remoteDrag(
            from: AppleFileTransferMessage.cancelDrop(sessionID: 0x1234)
        ))
    }

    func testComputesFileTransferStreamLengthsAndRejectsOversizedBodies() throws {
        let message = try AppleFileTransferMessage.senderData(
            sessionID: 0x1234,
            data: Data(repeating: 0x58, count: 65_536)
        )

        XCTAssertEqual(
            try AppleFileTransferMessage.expectedStreamMessageLength(from: message.prefix(6)),
            message.count
        )
        XCTAssertNil(try AppleFileTransferMessage.expectedStreamMessageLength(
            from: Data([0x20, 0, 0])
        ))
        var oversized = Data(repeating: 0, count: 6)
        oversized[0] = 0x22
        oversized.writeUInt32BE(
            UInt32(AppleFileTransferMessage.maximumFileCopyBodyLength + 1),
            at: 2
        )
        XCTAssertThrowsError(try AppleFileTransferMessage.expectedStreamMessageLength(
            from: oversized
        ))
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

    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
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
