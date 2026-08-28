import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import iScreenSharingMobile

@MainActor
final class MobileClipboardServiceTests: XCTestCase {
    func testLocalArchivePreservesInlineFlavorsAndFiltersFileURLs() throws {
        let pasteboard = makePasteboard()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let text = Data("hello".utf8)
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        pasteboard.setItems([[
            UTType.utf8PlainText.identifier: text,
            UTType.png.identifier: png,
            UTType.fileURL.identifier: Data("file:///tmp/private.txt".utf8),
        ]])
        let service = makeService(pasteboard: pasteboard)

        let flavors = try XCTUnwrap(service.localArchive()?.items.first?.flavors)

        XCTAssertEqual(flavors.first { $0.type == UTType.utf8PlainText.identifier }?.value, text)
        XCTAssertEqual(flavors.first { $0.type == UTType.png.identifier }?.value, png)
        XCTAssertFalse(flavors.contains { $0.type == UTType.fileURL.identifier })
    }

    func testReceivePreservesMultipleItemsAndResolvesMIMEAlias() throws {
        let pasteboard = makePasteboard()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        let service = makeService(pasteboard: pasteboard)

        service.receive(AppleClipboardArchive(items: [
            AppleClipboardItem(flavors: [
                AppleClipboardFlavor(
                    type: UTType.utf8PlainText.identifier,
                    aliases: [],
                    value: Data("one".utf8)
                ),
            ]),
            AppleClipboardItem(flavors: [
                AppleClipboardFlavor(
                    type: "",
                    aliases: [AppleClipboardTypeAlias(
                        tagClass: "public.mime-type",
                        preferredTag: "image/png"
                    )],
                    value: png
                ),
            ]),
        ]))

        XCTAssertEqual(pasteboard.numberOfItems, 2)
        XCTAssertEqual(
            pasteboard.data(forPasteboardType: UTType.png.identifier, inItemSet: IndexSet(integer: 1))?.first,
            png
        )
        XCTAssertEqual(service.lastReceivedText, "one")
    }

    private func makePasteboard() -> UIPasteboard {
        let name = UIPasteboard.Name("mobile-clipboard-tests-\(UUID().uuidString)")
        return UIPasteboard(name: name, create: true)!
    }

    private func makeService(pasteboard: UIPasteboard) -> MobileClipboardService {
        MobileClipboardService(
            pasteboard: pasteboard,
            advertise: { _ in },
            updateRemoteSharingEnabled: { _ in }
        )
    }
}
