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

    var appKitDisplayMode: NSToolbar.DisplayMode {
        switch self {
        case .iconOnly: .iconOnly
        case .iconAndText: .iconAndLabel
        }
    }

    init?(appKitDisplayMode: NSToolbar.DisplayMode) {
        switch appKitDisplayMode {
        case .iconOnly:
            self = .iconOnly
        case .iconAndLabel:
            self = .iconAndText
        default:
            return nil
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

    static func applyStoredPreferences(
        to window: NSWindow,
        defaults: UserDefaults = .standard
    ) {
        apply(
            to: window,
            isVisible: storedVisibility(in: defaults),
            displayMode: storedDisplayMode(in: defaults)
        )
    }

    static func store(
        displayMode: SessionToolbarDisplayMode,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(displayMode.rawValue, forKey: displayModeKey)
    }

    static func apply(
        to window: NSWindow,
        isVisible: Bool,
        displayMode: SessionToolbarDisplayMode
    ) {
        guard let toolbar = window.toolbar else { return }
        toolbar.allowsDisplayModeCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.displayMode = displayMode.appKitDisplayMode
        toolbar.isVisible = isVisible
    }
}
