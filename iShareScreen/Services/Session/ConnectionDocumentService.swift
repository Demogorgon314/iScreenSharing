import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ConnectionDocumentService {
    func openLocation() async throws -> ConnectionEndpoint? {
        let panel = NSOpenPanel()
        panel.title = "Open Connection"
        panel.prompt = "Open"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.allowedContentTypes
        guard await response(from: panel) == .OK, let url = panel.url else { return nil }
        return try await Self.endpoint(from: url)
    }

    func saveLocation(for endpoint: ConnectionEndpoint) async throws {
        let panel = NSSavePanel()
        panel.title = "Save Connection"
        panel.prompt = "Save"
        panel.allowedContentTypes = Self.allowedContentTypes
        panel.nameFieldStringValue = "\(Self.safeFilename(endpoint.displayName)).vncloc"
        guard await response(from: panel) == .OK, let url = panel.url else { return }
        try ConnectionLocationDocument.data(for: endpoint).write(to: url, options: .atomic)
    }

    static func endpoint(from url: URL) async throws -> ConnectionEndpoint {
        if !url.isFileURL { return try ConnectionEndpoint(url.absoluteString) }
        let data = try await Task.detached { try Data(contentsOf: url) }.value
        return try ConnectionLocationDocument.endpoint(from: data)
    }

    static func present(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The connection could not be opened."
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private static var allowedContentTypes: [UTType] {
        if let type = UTType(filenameExtension: ConnectionLocationDocument.fileExtension) {
            return [type]
        }
        return [.propertyList]
    }

    private static func safeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        let components = name.components(separatedBy: invalid).filter { !$0.isEmpty }
        return components.joined(separator: "-").isEmpty ? "Screen Sharing" : components.joined(separator: "-")
    }

    private func response(from panel: NSSavePanel) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
    }
}
