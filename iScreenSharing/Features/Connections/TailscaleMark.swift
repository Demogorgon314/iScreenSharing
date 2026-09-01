import AppKit
import SwiftUI

struct TailscaleMark: View {
    let size: CGFloat

    init(size: CGFloat = 16) {
        self.size = size
    }

    var body: some View {
        Image("TailscaleMark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

@MainActor
enum TailscaleMarkImage {
    static let settingsTab: NSImage = {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { bounds in
            let scale = min(bounds.width / size.width, bounds.height / size.height)
            let origin = CGPoint(
                x: bounds.midX - (size.width * scale / 2),
                y: bounds.midY - (size.height * scale / 2)
            )
            let centers: [(CGFloat, CGFloat, CGFloat)] = [
                (7, 7, 0.2), (12, 7, 0.2), (17, 7, 0.2),
                (7, 12, 1), (12, 12, 1), (17, 12, 1),
                (7, 17, 0.2), (12, 17, 1), (17, 17, 0.2),
            ]

            for (x, y, opacity) in centers {
                NSColor.black.withAlphaComponent(opacity).setFill()
                let circle = CGRect(
                    x: origin.x + ((x - 2) * scale),
                    y: origin.y + ((y - 2) * scale),
                    width: 4 * scale,
                    height: 4 * scale
                )
                NSBezierPath(ovalIn: circle).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}
