import AppKit
import SwiftUI

enum ScreenshotFileWriter {
    enum Error: LocalizedError {
        case unableToEncodePNG

        var errorDescription: String? {
            "The screenshot could not be encoded as a PNG image."
        }
    }

    static func write(
        _ image: NSImage,
        suggestedName: String = "Screen Sharing Screenshot",
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(
                using: .png,
                properties: [:]
              ) else { throw Error.unableToEncodePNG }

        let directory = temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appending(path: "\(safeFilename(suggestedName)).png")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func safeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        let components = name.components(separatedBy: invalid).filter { !$0.isEmpty }
        let filename = components.joined(separator: "-")
        return filename.isEmpty ? "Screen Sharing Screenshot" : filename
    }
}

@MainActor
enum ScreenshotSharingPicker {
    static func show(_ screenshotURL: URL, relativeTo anchorView: NSView) {
        NSSharingServicePicker(items: [screenshotURL]).show(
            relativeTo: anchorView.bounds,
            of: anchorView,
            preferredEdge: .minY
        )
    }
}

struct ScreenshotButtonAnchor: NSViewRepresentable {
    @Binding var anchorView: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        resolve(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard anchorView !== view else { return }
        resolve(view)
    }

    private func resolve(_ view: NSView) {
        DispatchQueue.main.async { anchorView = view }
    }
}
