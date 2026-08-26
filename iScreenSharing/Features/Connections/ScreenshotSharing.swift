import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ScreenshotImageData {
    enum Error: LocalizedError {
        case unableToEncodePNG

        var errorDescription: String? {
            "The screenshot could not be encoded as a PNG image."
        }
    }

    static func png(for image: NSImage) throws -> Data {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(
                using: .png,
                properties: [:]
              ) else { throw Error.unableToEncodePNG }
        return data
    }

    static func filename(
        for suggestedName: String,
        date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        let components = suggestedName.components(separatedBy: invalid).filter { !$0.isEmpty }
        let filename = components.joined(separator: "-")
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = filename.isEmpty ? "Screen Sharing Screenshot" : filename
        return "\(base) \(formatter.string(from: date)).png"
    }
}

enum ScreenshotClipboardWriter {
    @discardableResult
    static func write(
        _ image: NSImage,
        pngData: Data,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        if let tiffData = image.tiffRepresentation {
            item.setData(tiffData, forType: .tiff)
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}

@MainActor
final class ScreenshotSharingCoordinator: NSObject, @preconcurrency NSSharingServicePickerDelegate {
    private static var active: ScreenshotSharingCoordinator?

    private let image: NSImage
    private let pngData: Data
    private let suggestedName: String
    private weak var window: NSWindow?
    private let picker: NSSharingServicePicker

    init(image: NSImage, suggestedName: String, window: NSWindow?) throws {
        self.image = image
        pngData = try ScreenshotImageData.png(for: image)
        self.suggestedName = suggestedName
        self.window = window
        picker = NSSharingServicePicker(items: [image])
        super.init()
        picker.delegate = self
    }

    static func show(
        _ image: NSImage,
        suggestedName: String,
        relativeTo anchorView: NSView
    ) throws {
        active?.picker.close()
        let coordinator = try ScreenshotSharingCoordinator(
            image: image,
            suggestedName: suggestedName,
            window: anchorView.window
        )
        active = coordinator
        coordinator.picker.show(
            relativeTo: anchorView.bounds,
            of: anchorView,
            preferredEdge: .minY
        )
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        sharingServicesForItems items: [Any],
        proposedSharingServices proposedServices: [NSSharingService]
    ) -> [NSSharingService] {
        proposedServices + [copyService(), saveService()]
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self, Self.active === self else { return }
            Self.active = nil
        }
    }

    private func copyService() -> NSSharingService {
        let serviceImage = NSImage(
            systemSymbolName: "clipboard",
            accessibilityDescription: "Copy to Clipboard"
        ) ?? NSImage()
        let screenshot = image
        let pngData = pngData
        return NSSharingService(
            title: "Copy to Clipboard",
            image: serviceImage,
            alternateImage: nil
        ) {
            ScreenshotClipboardWriter.write(screenshot, pngData: pngData)
        }
    }

    private func saveService() -> NSSharingService {
        let serviceImage = NSImage(
            systemSymbolName: "square.and.arrow.down",
            accessibilityDescription: "Save As"
        ) ?? NSImage()
        let pngData = pngData
        let filename = ScreenshotImageData.filename(for: suggestedName)
        let window = window
        return NSSharingService(
            title: "Save As…",
            image: serviceImage,
            alternateImage: nil
        ) {
            Self.showSavePanel(pngData: pngData, filename: filename, window: window)
        }
    }

    private static func showSavePanel(
        pngData: Data,
        filename: String,
        window: NSWindow?
    ) {
        let panel = NSSavePanel()
        panel.title = "Save Screenshot"
        panel.prompt = "Save"
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = filename
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try pngData.write(to: url, options: .atomic)
            } catch {
                presentSaveError(error, window: window)
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private static func presentSaveError(_ error: Error, window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The screenshot could not be saved."
        alert.informativeText = error.localizedDescription
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
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
