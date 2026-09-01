import Foundation

enum AppleRemoteSystemCommand: UInt32, CaseIterable, Sendable {
    case missionControl = 0x1008_fd02
    case appWindows = 0x1008_fd03
    case desktop = 0x1008_fd01
    case launchpad = 0x1008_fd00

    var title: String {
        switch self {
        case .launchpad: "Launchpad"
        case .desktop: "Desktop"
        case .missionControl: "Mission Control"
        case .appWindows: "App Windows"
        }
    }

    var systemImage: String {
        switch self {
        case .launchpad: "square.grid.3x3.fill"
        case .desktop: "menubar.dock.rectangle"
        case .missionControl: "rectangle.3.group"
        case .appWindows: "macwindow.on.rectangle"
        }
    }
}
