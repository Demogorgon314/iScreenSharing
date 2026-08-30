import Darwin
import Foundation
import ScreenSharingProtocol
import XCTest
@testable import iScreenSharing

final class AppleSwiftFileCopyReceiverTests: XCTestCase {
    func testReceivesDirectoryTreeDataResourceForkSymlinkAndMetadata() throws {
        let destination = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let receiver = try AppleSwiftFileCopyReceiver(
            destinationDirectory: destination,
            requestedName: "Received"
        )
        var finderInfo = Data(repeating: 0, count: 32)
        finderInfo[8] = 0x40
        let date = AppleFileCopyUTCDateTime(seconds: 3_900_000_000, fraction: 0)

        _ = try receiver.receive(.summary(AppleFileCopySummary(
            rootIsFile: false,
            logicalBytes: 13,
            physicalBytes: 4_096,
            fileCount: 2,
            folderCount: 1
        )))
        _ = try receiver.receive(.item(metadata(
            type: .directory,
            finderInfo: finderInfo,
            level: 0,
            mode: 0o040755,
            name: "Source",
            date: date
        )))
        _ = try receiver.receive(.item(metadata(
            type: .file,
            finderInfo: finderInfo,
            resourceForkSize: 4,
            dataForkSize: 5,
            level: 1,
            mode: 0o100640,
            name: "file.txt",
            date: date,
            extendedAttributes: [
                AppleFileCopyExtendedAttribute(
                    name: "com.example.iScreenSharing.test",
                    value: Data("value".utf8)
                )
            ]
        )))
        _ = try receiver.receive(.data(Data("hello".utf8)))
        _ = try receiver.receive(.data(Data("rsrc".utf8)))
        _ = try receiver.receive(.item(metadata(
            type: .symbolicLink,
            dataForkSize: 4,
            level: 1,
            mode: 0o120755,
            name: "link",
            date: date,
            symbolicLinkTarget: Data("file.txt".utf8)
        )))
        let completion = try receiver.receive(.done(status: 0))

        let root = destination.appendingPathComponent("Received", isDirectory: true)
        let file = root.appendingPathComponent("file.txt")
        XCTAssertEqual(completion.completedURL, root)
        XCTAssertEqual(try Data(contentsOf: file), Data("hello".utf8))
        XCTAssertEqual(
            try extendedAttribute("com.apple.ResourceFork", at: file),
            Data("rsrc".utf8)
        )
        XCTAssertEqual(
            try extendedAttribute("com.example.iScreenSharing.test", at: file),
            Data("value".utf8)
        )
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: root.appendingPathComponent("link").path
        ), "file.txt")
        var fileStat = stat()
        XCTAssertEqual(lstat(file.path, &fileStat), 0)
        XCTAssertEqual(fileStat.st_mode & 0o777, 0o640)
    }

    func testReceivesContinuousCompressedSegmentsAndRenamesExistingRoot() throws {
        let destination = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let existing = destination.appendingPathComponent("file.bin")
        try Data("existing".utf8).write(to: existing)
        let receiver = try AppleSwiftFileCopyReceiver(
            destinationDirectory: destination,
            requestedName: "file.bin"
        )
        let first = Data(repeating: 0x41, count: 32_768)
        let second = Data(repeating: 0x42, count: 32_768)
        let compressor = try ZlibSyncFlushCompressor()

        _ = try receiver.receive(.summary(AppleFileCopySummary(
            rootIsFile: true,
            logicalBytes: 65_536,
            physicalBytes: 65_536,
            fileCount: 1,
            folderCount: 0
        )))
        _ = try receiver.receive(.item(metadata(
            type: .file,
            dataForkSize: 65_536,
            level: 0,
            mode: 0o100600,
            name: "remote.bin"
        )))
        _ = try receiver.receive(.compressedData(
            uncompressedLength: first.count,
            data: try compressor.compress(first)
        ))
        _ = try receiver.receive(.compressedData(
            uncompressedLength: second.count,
            data: try compressor.compress(second)
        ))
        let completion = try receiver.receive(.done(status: 0))

        let received = destination.appendingPathComponent("file 2.bin")
        XCTAssertEqual(completion.completedURL, received)
        XCTAssertEqual(try Data(contentsOf: received), first + second)
        XCTAssertEqual(try Data(contentsOf: existing), Data("existing".utf8))
    }

    func testRejectsOutOfOrderAndPathTraversalItemsWithoutDeletingPartialOutput() throws {
        let destination = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let receiver = try AppleSwiftFileCopyReceiver(
            destinationDirectory: destination,
            requestedName: "file"
        )

        XCTAssertThrowsError(try receiver.receive(.data(Data([1])))) {
            XCTAssertEqual($0 as? AppleSwiftFileCopyReceiverError, .invalidSequence)
        }
        _ = try receiver.receive(.summary(AppleFileCopySummary(
            rootIsFile: true,
            logicalBytes: 2,
            physicalBytes: 4_096,
            fileCount: 1,
            folderCount: 0
        )))
        XCTAssertThrowsError(try receiver.receive(.item(metadata(
            type: .file,
            dataForkSize: 2,
            level: 1,
            mode: 0o100600,
            name: "../escape"
        )))) {
            XCTAssertEqual($0 as? AppleSwiftFileCopyReceiverError, .invalidItem)
        }
        _ = try receiver.receive(.item(metadata(
            type: .file,
            dataForkSize: 2,
            level: 0,
            mode: 0o100600,
            name: "file"
        )))
        _ = try receiver.receive(.data(Data([1])))
        XCTAssertThrowsError(try receiver.receive(.done(status: 0))) {
            XCTAssertEqual($0 as? AppleSwiftFileCopyReceiverError, .invalidSequence)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("file").path
        ))
    }

    func testRemoteFailureCanEndBeforeAnyItemArrives() throws {
        let destination = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let receiver = try AppleSwiftFileCopyReceiver(
            destinationDirectory: destination,
            requestedName: "missing"
        )

        XCTAssertThrowsError(try receiver.receive(.done(status: -43))) {
            XCTAssertEqual(
                $0 as? AppleSwiftFileCopyReceiverError,
                .remoteFailed(-43)
            )
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: nil
        ).isEmpty)
    }

    func testExtendedAttributeFailureStopsLaterAttributesWithoutFailingTransfer() throws {
        let destination = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let receiver = try AppleSwiftFileCopyReceiver(
            destinationDirectory: destination,
            requestedName: "received.bin"
        )
        let laterName = "com.example.iScreenSharing.should-not-be-written"

        _ = try receiver.receive(.summary(AppleFileCopySummary(
            rootIsFile: true,
            logicalBytes: 0,
            physicalBytes: 0,
            fileCount: 1,
            folderCount: 0
        )))
        _ = try receiver.receive(.item(metadata(
            type: .file,
            level: 0,
            mode: 0o100600,
            name: "remote.bin",
            extendedAttributes: [
                AppleFileCopyExtendedAttribute(name: "", value: Data([0x01])),
                AppleFileCopyExtendedAttribute(name: laterName, value: Data([0x02]))
            ]
        )))
        let completion = try receiver.receive(.done(status: 0))

        XCTAssertEqual(completion.completedURL?.lastPathComponent, "received.bin")
        let result = getxattr(
            destination.appendingPathComponent("received.bin").path,
            laterName,
            nil,
            0,
            0,
            XATTR_NOFOLLOW
        )
        XCTAssertEqual(result, -1)
        XCTAssertEqual(errno, ENOATTR)
    }

    func testSkipsOverlongNestedSymbolicLinkAndContinuesWithSibling() throws {
        let destination = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let receiver = try AppleSwiftFileCopyReceiver(
            destinationDirectory: destination,
            requestedName: "Received"
        )

        _ = try receiver.receive(.summary(AppleFileCopySummary(
            rootIsFile: false,
            logicalBytes: 1_024,
            physicalBytes: 0,
            fileCount: 2,
            folderCount: 1
        )))
        _ = try receiver.receive(.item(metadata(
            type: .directory,
            level: 0,
            mode: 0o040755,
            name: "Source"
        )))
        _ = try receiver.receive(.item(metadata(
            type: .symbolicLink,
            dataForkSize: 1_024,
            level: 1,
            mode: 0o120755,
            name: "too-long",
            symbolicLinkTarget: Data(repeating: 0x61, count: 1_024)
        )))
        _ = try receiver.receive(.item(metadata(
            type: .file,
            level: 1,
            mode: 0o100600,
            name: "sibling.txt"
        )))
        _ = try receiver.receive(.done(status: 0))

        let root = destination.appendingPathComponent("Received", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("too-long").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("sibling.txt").path
        ))
    }

    func testPreservesNonUTF8SymbolicLinkTargetBytes() throws {
        let destination = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let receiver = try AppleSwiftFileCopyReceiver(
            destinationDirectory: destination,
            requestedName: "Received"
        )
        let target = Data([0x66, 0x6f, 0x80])

        _ = try receiver.receive(.summary(AppleFileCopySummary(
            rootIsFile: false,
            logicalBytes: UInt64(target.count),
            physicalBytes: 0,
            fileCount: 1,
            folderCount: 1
        )))
        _ = try receiver.receive(.item(metadata(
            type: .directory,
            level: 0,
            mode: 0o040755,
            name: "Source"
        )))
        _ = try receiver.receive(.item(metadata(
            type: .symbolicLink,
            dataForkSize: UInt64(target.count),
            level: 1,
            mode: 0o120755,
            name: "raw-link",
            symbolicLinkTarget: target
        )))
        _ = try receiver.receive(.done(status: 0))

        let link = destination
            .appendingPathComponent("Received", isDirectory: true)
            .appendingPathComponent("raw-link")
        XCTAssertEqual(try symbolicLinkTarget(at: link), target)
    }

    func testIncompleteRootKeepsNative1984AndKorbMarkers() throws {
        let destination = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let receiver = try AppleSwiftFileCopyReceiver(
            destinationDirectory: destination,
            requestedName: "partial.bin"
        )
        var finderInfo = Data(repeating: 0, count: 32)
        finderInfo.replaceSubrange(0..<8, with: Data("TEXTttxt".utf8))

        _ = try receiver.receive(.summary(AppleFileCopySummary(
            rootIsFile: true,
            logicalBytes: 2,
            physicalBytes: 4_096,
            fileCount: 1,
            folderCount: 0
        )))
        _ = try receiver.receive(.item(metadata(
            type: .file,
            finderInfo: finderInfo,
            dataForkSize: 2,
            level: 0,
            mode: 0o100600,
            name: "remote.bin",
            date: AppleFileCopyUTCDateTime(seconds: 3_900_000_000, fraction: 0)
        )))
        _ = try receiver.receive(.data(Data([0x58])))

        let partial = destination.appendingPathComponent("partial.bin")
        var value = stat()
        XCTAssertEqual(lstat(partial.path, &value), 0)
        XCTAssertEqual(value.st_birthtimespec.tv_sec, 443_779_200)
        XCTAssertEqual(
            try extendedAttribute("com.apple.FinderInfo", at: partial).prefix(4),
            Data("korb".utf8)
        )
    }

    private func metadata(
        type: AppleFileCopyItemType,
        finderInfo: Data = Data(repeating: 0, count: 32),
        resourceForkSize: UInt64 = 0,
        dataForkSize: UInt64 = 0,
        level: UInt16,
        mode: UInt16,
        name: String,
        date: AppleFileCopyUTCDateTime = .zero,
        symbolicLinkTarget: Data? = nil,
        extendedAttributes: [AppleFileCopyExtendedAttribute] = []
    ) -> AppleFileCopyItemMetadata {
        AppleFileCopyItemMetadata(
            type: type,
            finderInfo: finderInfo,
            resourceForkSize: resourceForkSize,
            dataForkSize: dataForkSize,
            creationDate: date,
            contentModificationDate: date,
            attributeModificationDate: date,
            accessDate: date,
            backupDate: date,
            nodeFlags: type == .directory ? 0x10 : 0,
            level: level,
            mode: mode,
            textEncodingHint: 0x7e,
            name: name,
            symbolicLinkTarget: symbolicLinkTarget,
            extendedAttributes: extendedAttributes
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-copy-receiver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func extendedAttribute(_ name: String, at url: URL) throws -> Data {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { throw CocoaError(.fileReadUnknown) }
        var value = Data(count: size)
        let count = value.withUnsafeMutableBytes { bytes in
            getxattr(url.path, name, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
        }
        guard count == size else { throw CocoaError(.fileReadUnknown) }
        return value
    }

    private func symbolicLinkTarget(at url: URL) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let count = buffer.withUnsafeMutableBytes { bytes in
            readlink(
                url.path,
                bytes.bindMemory(to: CChar.self).baseAddress,
                bytes.count
            )
        }
        guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
        return Data(buffer.prefix(count))
    }
}
