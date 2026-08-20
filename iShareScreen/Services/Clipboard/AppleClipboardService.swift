import AppKit
import Combine
import Foundation

@MainActor
protocol AppleClipboardReceiving: AnyObject {
    func receive(_ text: String)
}

@MainActor
final class AppleClipboardService: ObservableObject, AppleClipboardReceiving {
    @Published private(set) var lastReceivedText: String?

    func localText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    func receive(_ text: String) {
        guard localText() != text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastReceivedText = text
    }
}
