import AppKit
import struct ScreenSharingProtocol.AppleClipboardArchive
import struct ScreenSharingProtocol.AppleClipboardFlavor
import struct ScreenSharingProtocol.AppleClipboardItem
import struct ScreenSharingProtocol.AppleClipboardTypeAlias
import XCTest
@testable import iScreenSharing

@MainActor
final class AppleClipboardServiceTests: XCTestCase {
    func testCapturesRichClipboardAndFiltersFileTransferTypes() throws {
        let pasteboard = makePasteboard()
        let item = NSPasteboardItem()
        item.setString("Hello", forType: .string)
        item.setData(Data("{\\rtf1 Hello}".utf8), forType: .rtf)
        item.setData(Data([0x89, 0x50, 0x4e, 0x47]), forType: .png)
        item.setString("file:///tmp/example.txt", forType: .fileURL)
        item.setData(Data([1, 2]), forType: .init("com.example.custom"))
        pasteboard.writeObjects([item])
        let service = AppleClipboardService(pasteboard: pasteboard)

        let archive = try XCTUnwrap(service.localArchive())
        let flavors = try XCTUnwrap(archive.items.first?.flavors)
        let types = Set(flavors.map(\.type))

        XCTAssertTrue(types.contains(NSPasteboard.PasteboardType.string.rawValue))
        XCTAssertTrue(types.contains(NSPasteboard.PasteboardType.rtf.rawValue))
        XCTAssertTrue(types.contains(NSPasteboard.PasteboardType.png.rawValue))
        XCTAssertTrue(types.contains("com.example.custom"))
        XCTAssertFalse(types.contains(NSPasteboard.PasteboardType.fileURL.rawValue))
    }

    func testInstallsMultipleItemsWithoutFlatteningFlavors() throws {
        let pasteboard = makePasteboard()
        let archive = AppleClipboardArchive(items: [
            AppleClipboardItem(flavors: [
                AppleClipboardFlavor(
                    type: NSPasteboard.PasteboardType.string.rawValue,
                    aliases: [],
                    value: Data("Hello".utf8)
                ),
                AppleClipboardFlavor(
                    type: NSPasteboard.PasteboardType.rtf.rawValue,
                    aliases: [],
                    value: Data("{\\rtf1 Hello}".utf8)
                )
            ]),
            AppleClipboardItem(flavors: [
                AppleClipboardFlavor(
                    type: NSPasteboard.PasteboardType.png.rawValue,
                    aliases: [],
                    value: Data([0x89, 0x50, 0x4e, 0x47])
                )
            ])
        ])
        let service = AppleClipboardService(pasteboard: pasteboard)

        service.receive(archive)

        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].string(forType: .string), "Hello")
        XCTAssertEqual(items[0].data(forType: .rtf), Data("{\\rtf1 Hello}".utf8))
        XCTAssertEqual(items[1].data(forType: .png), Data([0x89, 0x50, 0x4e, 0x47]))
        XCTAssertEqual(service.lastReceivedText, "Hello")
    }

    func testResolvesAliasOnlyClipboardFlavorType() throws {
        let pasteboard = makePasteboard()
        let service = AppleClipboardService(pasteboard: pasteboard)
        let archive = AppleClipboardArchive(items: [
            AppleClipboardItem(flavors: [
                AppleClipboardFlavor(
                    type: "",
                    aliases: [AppleClipboardTypeAlias(
                        tagClass: "public.mime-type",
                        preferredTag: "image/png"
                    )],
                    value: Data([0x89, 0x50, 0x4e, 0x47])
                )
            ])
        ])

        service.receive(archive)

        XCTAssertEqual(
            pasteboard.pasteboardItems?.first?.data(forType: .png),
            Data([0x89, 0x50, 0x4e, 0x47])
        )
    }

    func testRemoteWriteUpdatesChangeCountBaselineAndDoesNotAdvertiseBack() async {
        let pasteboard = makePasteboard()
        let recorder = ClipboardAdvertisementRecorder()
        let service = AppleClipboardService(
            pasteboard: pasteboard,
            advertise: { archive in await recorder.record(archive) },
            isApplicationActive: { true }
        )
        service.start()
        service.setSessionWindow(UUID(), isKey: true)
        service.receive(.text("remote"))

        await Task.yield()

        let advertisementCount = await recorder.count
        XCTAssertEqual(advertisementCount, 0)
        service.close()
    }

    func testAdvertisesEachLocalChangeOnlyOnceWhenSessionBecomesKey() async throws {
        let pasteboard = makePasteboard()
        let recorder = ClipboardAdvertisementRecorder()
        let service = AppleClipboardService(
            pasteboard: pasteboard,
            advertise: { archive in await recorder.record(archive) },
            isApplicationActive: { true }
        )
        service.start()
        let windowID = UUID()
        pasteboard.clearContents()
        pasteboard.setString("local", forType: .string)

        service.setSessionWindow(windowID, isKey: true)
        for _ in 0..<100 {
            if await recorder.count == 1 { break }
            await Task.yield()
        }
        service.setSessionWindow(windowID, isKey: true)
        await Task.yield()

        let advertisementCount = await recorder.count
        let lastArchive = await recorder.lastArchive()
        let archive = try XCTUnwrap(lastArchive)
        XCTAssertEqual(advertisementCount, 1)
        XCTAssertEqual(archive.preferredText, "local")
        service.close()
    }

    func testOnlyTheFocusedSessionAdvertisesTheSharedPasteboard() async {
        let pasteboard = makePasteboard()
        let firstRecorder = ClipboardAdvertisementRecorder()
        let secondRecorder = ClipboardAdvertisementRecorder()
        let first = AppleClipboardService(
            pasteboard: pasteboard,
            advertise: { archive in await firstRecorder.record(archive) },
            isApplicationActive: { true }
        )
        let second = AppleClipboardService(
            pasteboard: pasteboard,
            advertise: { archive in await secondRecorder.record(archive) },
            isApplicationActive: { true }
        )
        first.start()
        second.start()
        pasteboard.clearContents()
        pasteboard.setString("private to the focused session", forType: .string)

        first.setSessionWindow(UUID(), isKey: true)
        for _ in 0..<100 {
            if await firstRecorder.count == 1 { break }
            await Task.yield()
        }

        let firstCount = await firstRecorder.count
        let secondCount = await secondRecorder.count
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 0)
        first.close()
        second.close()
    }

    func testFocusLeasePreventsLateRemoteClipboardInstallation() throws {
        let pasteboard = makePasteboard()
        let service = AppleClipboardService(
            pasteboard: pasteboard,
            isApplicationActive: { true }
        )
        service.start()
        let windowID = UUID()
        service.setSessionWindow(windowID, isKey: true)
        let lease = try XCTUnwrap(service.synchronizationLease())

        service.setSessionWindow(windowID, isKey: false)

        XCTAssertFalse(service.receiveIfEligible(.text("remote"), lease: lease))
        XCTAssertNil(pasteboard.string(forType: .string))
        service.close()
    }

    func testFailedAdvertisementDoesNotAdvanceChangeCountBaseline() async {
        let pasteboard = makePasteboard()
        let recorder = ClipboardAdvertisementRecorder(failuresRemaining: 1)
        let service = AppleClipboardService(
            pasteboard: pasteboard,
            advertise: { archive in try await recorder.recordOrFail(archive) },
            isApplicationActive: { true }
        )
        service.start()
        pasteboard.clearContents()
        pasteboard.setString("retry", forType: .string)
        let firstWindow = UUID()
        service.setSessionWindow(firstWindow, isKey: true)
        for _ in 0..<100 {
            if await recorder.attemptCount == 1 { break }
            await Task.yield()
        }
        service.setSessionWindow(firstWindow, isKey: false)
        service.setSessionWindow(firstWindow, isKey: true)
        for _ in 0..<100 {
            if await recorder.attemptCount == 2 { break }
            await Task.yield()
        }

        let attempts = await recorder.attemptCount
        let successfulArchive = await recorder.lastArchive()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(successfulArchive?.preferredText, "retry")
        service.close()
    }

    func testRemoteDataRequestReadsCurrentPasteboardInsteadOfAdvertisedSnapshot() async throws {
        let pasteboard = makePasteboard()
        let recorder = ClipboardAdvertisementRecorder()
        let advertised = expectation(description: "Pasteboard promises advertised")
        let service = AppleClipboardService(
            pasteboard: pasteboard,
            advertise: { archive in
                await recorder.record(archive)
                advertised.fulfill()
            },
            isApplicationActive: { true }
        )
        service.start()
        pasteboard.clearContents()
        pasteboard.setString("advertised", forType: .string)
        service.setSessionWindow(UUID(), isKey: true)
        await fulfillment(of: [advertised], timeout: 1)

        pasteboard.clearContents()
        pasteboard.setString("current", forType: .string)

        XCTAssertEqual(service.archiveForRemoteRequest()?.preferredText, "current")
        service.close()
    }

    func testSharedClipboardToggleUpdatesSessionStateAndRemoteMode() async {
        let enabled = expectation(description: "Shared clipboard enabled remotely")
        let disabled = expectation(description: "Shared clipboard disabled remotely")
        let service = AppleClipboardService(
            pasteboard: makePasteboard(),
            updateRemoteSharingEnabled: { isEnabled in
                if isEnabled {
                    enabled.fulfill()
                } else {
                    disabled.fulfill()
                }
            },
            isApplicationActive: { true }
        )

        service.start()
        await fulfillment(of: [enabled], timeout: 1)
        XCTAssertTrue(service.isSharingEnabled)

        service.setSharingEnabled(false)
        await fulfillment(of: [disabled], timeout: 1)
        XCTAssertFalse(service.isSharingEnabled)
        service.close()
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("clipboard-tests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }
}

private actor ClipboardAdvertisementRecorder {
    private var archives = [AppleClipboardArchive]()
    private var failuresRemaining: Int
    private(set) var attemptCount = 0
    var count: Int { archives.count }
    func lastArchive() -> AppleClipboardArchive? { archives.last }

    init(failuresRemaining: Int = 0) {
        self.failuresRemaining = failuresRemaining
    }

    func record(_ archive: AppleClipboardArchive) {
        attemptCount += 1
        archives.append(archive)
    }

    func recordOrFail(_ archive: AppleClipboardArchive) throws {
        attemptCount += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw ClipboardAdvertisementError.failed
        }
        archives.append(archive)
    }
}

private enum ClipboardAdvertisementError: Error {
    case failed
}
