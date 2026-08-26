import AppKit
import XCTest
@testable import iShareScreen

final class ScreenshotSharingTests: XCTestCase {
    func testWritesNamedPNGFileForSystemSharingServices() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let url = try ScreenshotFileWriter.write(
            makeImage(width: 4, height: 2),
            suggestedName: "Screenshot deepdream’s Mac mini",
            in: temporaryDirectory
        )

        XCTAssertEqual(url.lastPathComponent, "Screenshot deepdream’s Mac mini.png")
        XCTAssertTrue(url.isFileURL)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.prefix(8), Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
        let representation = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(representation.pixelsWide, 4)
        XCTAssertEqual(representation.pixelsHigh, 2)
    }

    func testPropagatesTemporaryDirectoryCreationFailure() throws {
        let fileURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data().write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertThrowsError(
            try ScreenshotFileWriter.write(makeImage(width: 1, height: 1), in: fileURL)
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
