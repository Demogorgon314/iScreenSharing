import AppKit
import SwiftUI

@MainActor
final class ScreenSharingAppDelegate: NSObject, NSApplicationDelegate {
    private static let menuTrackingObserver = ConnectionMenuTrackingObserver()
    private static var isConfiguringMenu = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            Self.configureConnectionMenu()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Self.configureConnectionMenu()
    }

    func applicationDidUpdate(_ notification: Notification) {
        Self.configureConnectionMenu()
    }

    static func configureConnectionMenu() {
        guard !isConfiguringMenu else { return }
        isConfiguringMenu = true
        defer { isConfiguringMenu = false }
        guard let menu = NSApp.mainMenu,
              let item = menu.items.first(where: { $0.title == "Connection" }) else { return }
        if let fileItem = menu.items.first(where: { $0.title == "File" }) {
            menu.removeItem(fileItem)
        }
        if menu.index(of: item) != 1 {
            menu.removeItem(item)
            menu.insertItem(item, at: min(1, menu.items.count))
        }
        item.title = "Connection"
        item.submenu?.title = "Connection"
    }

    static func installConnectionMenu() {
        menuTrackingObserver.start()
        DispatchQueue.main.async {
            configureConnectionMenu()
        }
    }

}

@MainActor
private final class ConnectionMenuTrackingObserver: NSObject {
    private var isObserving = false

    func start() {
        guard !isObserving else { return }
        isObserving = true
        for name in [
            NSMenu.didAddItemNotification,
            NSMenu.didRemoveItemNotification,
            NSMenu.didChangeItemNotification,
            NSMenu.didBeginTrackingNotification,
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(menuDidChange(_:)),
                name: name,
                object: nil
            )
        }
    }

    @objc private func menuDidChange(_ notification: Notification) {
        ScreenSharingAppDelegate.configureConnectionMenu()
    }
}

private struct ConnectionMenuTitleModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                ScreenSharingAppDelegate.installConnectionMenu()
            }
    }
}

extension View {
    func installsConnectionMenuTitle() -> some View {
        modifier(ConnectionMenuTitleModifier())
    }
}
