import Foundation

struct AppleVideoDisplayScheduler {
    private(set) var needsPresentation = false

    mutating func markNeedsPresentation() {
        needsPresentation = true
    }

    mutating func displayLinkDidFire(
        present: () -> Bool
    ) {
        guard needsPresentation,
              present() else { return }
        needsPresentation = false
    }
}
