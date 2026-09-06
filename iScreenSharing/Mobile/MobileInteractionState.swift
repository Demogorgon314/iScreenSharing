import CoreGraphics
import Foundation
import struct ScreenSharingProtocol.AppleScrollWheelEvent

/// Serializes mobile input and lets interruptions discard unsent gestures.
@MainActor
final class MobileInputQueue {
    private var generation: UInt64 = 0
    private var tail = Task<Void, Never> {}

    @discardableResult
    func enqueue(_ operation: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        let predecessor = tail
        let generation = generation
        let task = Task { [weak self] in
            await predecessor.value
            guard !Task.isCancelled, self?.generation == generation else { return }
            await operation()
        }
        tail = task
        return task
    }

    func cancelPending(releasing operation: @escaping @MainActor @Sendable () async -> Void) {
        generation &+= 1
        let predecessor = tail
        // A release is a barrier, not a gesture: a later cancellation must not
        // discard it, and it must follow any already-started transport write.
        tail = Task {
            await predecessor.value
            await operation()
        }
    }
}

enum MobileKeyboardModifier: UInt32, CaseIterable {
    case command = 0xffeb
    case option = 0xffe9
    case control = 0xffe3
    case shift = 0xffe1

    var title: String {
        switch self {
        case .command: "⌘"
        case .option: "⌥"
        case .control: "Ctrl"
        case .shift: "⇧"
        }
    }
}

struct MobileKeyboardState {
    struct Event: Equatable {
        let symbol: UInt32
        let isDown: Bool
    }

    private(set) var modifiers = Set<MobileKeyboardModifier>()

    mutating func toggle(_ modifier: MobileKeyboardModifier) {
        if !modifiers.insert(modifier).inserted { modifiers.remove(modifier) }
    }

    mutating func consume(
        symbol: UInt32,
        explicitModifiers: Set<MobileKeyboardModifier>? = nil
    ) -> [Event] {
        // Named shortcuts must not inherit an accidentally armed modifier.
        let effectiveModifiers = explicitModifiers ?? modifiers
        let selected = MobileKeyboardModifier.allCases.filter { effectiveModifiers.contains($0) }
        reset()
        return selected.map { Event(symbol: $0.rawValue, isDown: true) }
            + [Event(symbol: symbol, isDown: true), Event(symbol: symbol, isDown: false)]
            + selected.reversed().map { Event(symbol: $0.rawValue, isDown: false) }
    }

    mutating func reset() { modifiers.removeAll() }
}

struct MobileScrollState {
    struct Movement {
        let event: AppleScrollWheelEvent
        let horizontalTicks: Int
        let verticalTicks: Int
    }

    private var points = CGPoint.zero
    private var wheelRemainder = CGPoint.zero

    mutating func reset() {
        points = .zero
        wheelRemainder = .zero
    }

    mutating func consume(translation: CGPoint) -> Movement? {
        guard translation.x.isFinite, translation.y.isFinite else { return nil }
        // Natural touch scrolling: content follows the fingers. Keep the same
        // direction for precise events and legacy wheel-button fallback.
        let x = max(-32_000, min(32_000, translation.x))
        let y = max(-32_000, min(32_000, translation.y))
        points.x += x
        points.y += y
        wheelRemainder.x += x
        wheelRemainder.y += y
        let pixelX = Int32(points.x.rounded(.towardZero))
        let pixelY = Int32(points.y.rounded(.towardZero))
        points.x -= CGFloat(pixelX)
        points.y -= CGFloat(pixelY)
        let ticksX = Int(wheelRemainder.x / 12)
        let ticksY = Int(wheelRemainder.y / 12)
        wheelRemainder.x -= CGFloat(ticksX * 12)
        wheelRemainder.y -= CGFloat(ticksY * 12)
        guard pixelX != 0 || pixelY != 0 || ticksX != 0 || ticksY != 0 else { return nil }
        return Movement(
            event: Self.pixelEvent(x: pixelX, y: pixelY),
            horizontalTicks: ticksX,
            verticalTicks: ticksY
        )
    }

    static func pixelEvent(x: Int32, y: Int32) -> AppleScrollWheelEvent {
        // Matches CGEvent(.pixel) fields on macOS 26.6.2 (25G83), guarded by
        // a CoreGraphics oracle test. No momentum or touch phases are invented.
        func lines(_ pixels: Int32) -> Int16 {
            guard pixels != 0 else { return 0 }
            return Int16(clamping: pixels / 10 == 0 ? (pixels > 0 ? 1 : -1) : pixels / 10)
        }
        return AppleScrollWheelEvent(
            deltaX: lines(x), deltaY: lines(y), deltaZ: 0,
            fixedDeltaX: Int32(clamping: Int64(x) * 65_536 / 10),
            fixedDeltaY: Int32(clamping: Int64(y) * 65_536 / 10), fixedDeltaZ: 0,
            pointDeltaX: x, pointDeltaY: y, pointDeltaZ: 0,
            scrollPhase: 0, momentumPhase: 0, scrollCount: 0, flags: 0
        )
    }
}
