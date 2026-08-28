import Foundation

/// Coalesces the tiles that the sender assigned to one logical video frame.
/// The sender may update any sparse subset of tiles, so neither tile count nor
/// tile position is a frame boundary.
final class AppleVideoTileFrameSynchronizer: @unchecked Sendable {
    private struct Group {
        var submittedTiles = [Int]()
        var submittedTileSet = Set<Int>()
        var decodedFrames = [Int: AppleHEVCDecoder.DecodedFrame]()
        var isClosed = false
    }

    private let lock = NSLock()
    private var groups = [UInt16: Group]()
    private var groupOrder = [UInt16]()
    private var currentFrameSequenceNumber: UInt16?
    private var flushScheduled = false

    /// Returns true when this submission closes a previously decoded logical
    /// frame. A frame remains open until the sender advances its sequence;
    /// decoder callbacks are not frame-boundary evidence.
    func recordSubmission(
        frameSequenceNumber: UInt16?,
        tileIndex: Int,
        subframeBoundary: AppleHEVCSubframeBoundaryParser.Boundary = .unknown
    ) -> Bool {
        guard let frameSequenceNumber else { return false }
        return lock.withTileFrameSynchronizerLock {
            if let currentFrameSequenceNumber,
               currentFrameSequenceNumber != frameSequenceNumber,
               var current = groups[currentFrameSequenceNumber] {
                current.isClosed = true
                groups[currentFrameSequenceNumber] = current
            }
            if groups[frameSequenceNumber] == nil {
                groups[frameSequenceNumber] = Group()
                groupOrder.append(frameSequenceNumber)
            }
            currentFrameSequenceNumber = frameSequenceNumber
            guard var group = groups[frameSequenceNumber] else { return false }
            if group.submittedTileSet.insert(tileIndex).inserted {
                group.submittedTiles.append(tileIndex)
            }
            if subframeBoundary == .last {
                group.isClosed = true
            }
            groups[frameSequenceNumber] = group
            return scheduleFlushIfReady()
        }
    }

    /// Returns true once per queue-drain cycle. The caller must schedule
    /// `drainReadyBatches()` on the ordered playback queue.
    func recordDecodedFrame(_ frame: AppleHEVCDecoder.DecodedFrame) -> Bool {
        guard case let .tile(tileIndex) = frame.region,
              let frameSequenceNumber = frame.accessUnitTiming?.observedFrameSequenceNumber else {
            return false
        }
        return lock.withTileFrameSynchronizerLock {
            guard var group = groups[frameSequenceNumber],
                  group.submittedTileSet.contains(tileIndex) else { return false }
            group.decodedFrames[tileIndex] = frame
            groups[frameSequenceNumber] = group
            return scheduleFlushIfReady()
        }
    }

    func recordDecodeFailure(frameSequenceNumber: UInt16?, tileIndex: Int) -> Bool {
        guard let frameSequenceNumber else { return false }
        return lock.withTileFrameSynchronizerLock {
            guard var group = groups[frameSequenceNumber] else { return false }
            group.submittedTileSet.remove(tileIndex)
            group.submittedTiles.removeAll { $0 == tileIndex }
            groups[frameSequenceNumber] = group
            return scheduleFlushIfReady()
        }
    }

    func drainReadyBatches() -> [[AppleHEVCDecoder.DecodedFrame]] {
        lock.withTileFrameSynchronizerLock {
            flushScheduled = false
            var batches = [[AppleHEVCDecoder.DecodedFrame]]()
            while let frameSequenceNumber = groupOrder.first,
                  let group = groups[frameSequenceNumber] {
                guard group.isClosed,
                      group.decodedFrames.count == group.submittedTileSet.count else { break }
                groupOrder.removeFirst()
                groups.removeValue(forKey: frameSequenceNumber)
                let batch = group.submittedTiles.compactMap { group.decodedFrames[$0] }
                if !batch.isEmpty { batches.append(batch) }
            }
            return batches
        }
    }

    func reset() {
        lock.withTileFrameSynchronizerLock {
            groups.removeAll(keepingCapacity: false)
            groupOrder.removeAll(keepingCapacity: false)
            currentFrameSequenceNumber = nil
            flushScheduled = false
        }
    }

    private func scheduleFlushIfReady() -> Bool {
        guard !flushScheduled,
              let first = groupOrder.first,
              let group = groups[first],
              group.isClosed,
              group.decodedFrames.count == group.submittedTileSet.count else {
            return false
        }
        flushScheduled = true
        return true
    }
}

private extension NSLock {
    func withTileFrameSynchronizerLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
