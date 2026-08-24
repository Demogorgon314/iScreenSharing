import AppKit

enum SessionToolbarDisplayMode: String, CaseIterable, Identifiable {
    case iconOnly
    case iconAndText

    var id: Self { self }

    var title: String {
        switch self {
        case .iconOnly: "Icon Only"
        case .iconAndText: "Icon and Text"
        }
    }

    fileprivate var appKitDisplayMode: NSToolbar.DisplayMode {
        switch self {
        case .iconOnly: .iconOnly
        case .iconAndText: .iconAndLabel
        }
    }
}

@MainActor
enum SessionToolbarPreferences {
    static let isVisibleKey = "sessionToolbarIsVisible"
    static let displayModeKey = "sessionToolbarDisplayMode"

    static func storedVisibility(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: isVisibleKey) != nil else { return true }
        return defaults.bool(forKey: isVisibleKey)
    }

    static func storedDisplayMode(
        in defaults: UserDefaults = .standard
    ) -> SessionToolbarDisplayMode {
        guard let rawValue = defaults.string(forKey: displayModeKey),
              let displayMode = SessionToolbarDisplayMode(rawValue: rawValue) else {
            return .iconOnly
        }
        return displayMode
    }

    static func applyStoredPreferences(to window: NSWindow) {
        apply(
            to: window,
            isVisible: storedVisibility(),
            displayMode: storedDisplayMode()
        )
    }

    static func apply(
        to window: NSWindow,
        isVisible: Bool,
        displayMode: SessionToolbarDisplayMode
    ) {
        guard let toolbar = window.toolbar else { return }
        toolbar.allowsDisplayModeCustomization = false
        toolbar.displayMode = displayMode.appKitDisplayMode
        toolbar.isVisible = isVisible
    }
}
