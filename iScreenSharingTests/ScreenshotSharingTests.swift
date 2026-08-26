import AppKit
import XCTest
@testable import iScreenSharing

@MainActor
final class ScreenshotSharingTests: XCTestCase {
    func testAddsCopyAndSaveCommandsToSystemSharingServices() throws {
        let image = makeImage(width: 4, height: 2)
        let coordinator = try ScreenshotSharingCoordinator(
            image: image,
            suggestedName: "Screenshot Remote Mac",
            window: nil
        )
        let picker = NSSharingServicePicker(items: [image])

        let services = coordinator.sharingServicePicker(
            picker,
            sharingServicesForItems: [image],
            proposedSharingServices: []
        )

        XCTAssertEqual(services.map(\.title), ["Copy to Clipboard", "Save As…"])
    }

    func testWritesPNGAndTIFFRepresentationsToClipboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let image = makeImage(width: 4, height: 2)
        let pngData = try ScreenshotImageData.png(for: image)

        XCTAssertTrue(ScreenshotClipboardWriter.write(image, pngData: pngData, to: pasteboard))
        XCTAssertEqual(pasteboard.data(forType: .png), pngData)
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
    }

    func testBuildsSafeSuggestedPNGFilenameWithTimestamp() {
        let date = Date(timeIntervalSince1970: 1_787_715_030)
        let timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!

        XCTAssertEqual(
            ScreenshotImageData.filename(
                for: "Screenshot Mac/Studio:2",
                date: date,
                timeZone: timeZone
            ),
            "Screenshot Mac-Studio-2 2026-08-26 at 11.30.30.png"
        )
        XCTAssertEqual(
            ScreenshotImageData.filename(for: "/:", date: date, timeZone: timeZone),
            "Screen Sharing Screenshot 2026-08-26 at 11.30.30.png"
        )
    }

    private func makeImage(width: Int, height: Int) -> NSImage {
        let pixels = Data(repeating: 0x80, count: width * height * 4)
        let provider = CGDataProvider(data: pixels as CFData)!
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }
}
