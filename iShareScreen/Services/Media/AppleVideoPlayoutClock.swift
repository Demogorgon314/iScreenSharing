import Foundation

struct AppleVideoPlayoutClock {
    private let clockRate: Double
    private let discontinuityThreshold: TimeInterval
    private var previousTimestamp: UInt32?
    private var previousPresentationTime: TimeInterval?

    init(
        clockRate: UInt32 = 90_000,
        discontinuityThreshold: TimeInterval = 2
    ) {
        precondition(clockRate > 0)
        precondition(discontinuityThreshold > 0)
        self.clockRate = Double(clockRate)
        self.discontinuityThreshold = discontinuityThreshold
    }

    mutating func presentationTime(
        for timestamp: UInt32,
        hostTime: TimeInterval
    ) -> TimeInterval {
        guard let previousTimestamp, let previousPresentationTime else {
            self.previousTimestamp = timestamp
            self.previousPresentationTime = hostTime
            return hostTime
        }
        guard timestamp != previousTimestamp else { return previousPresentationTime }

        let ticks = Int32(bitPattern: timestamp &- previousTimestamp)
        let delta = Double(ticks) / clockRate
        let candidate = previousPresentationTime + delta
        let presentationTime: TimeInterval
        if abs(delta) >= discontinuityThreshold {
            presentationTime = hostTime
        } else if candidate < previousPresentationTime {
            presentationTime = previousPresentationTime
        } else {
            presentationTime = candidate
        }

        self.previousTimestamp = timestamp
        self.previousPresentationTime = presentationTime
        return presentationTime
    }

    mutating func reset() {
        previousTimestamp = nil
        previousPresentationTime = nil
    }
}
