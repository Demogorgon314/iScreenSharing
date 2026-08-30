import Foundation
import enum ScreenSharingProtocol.AppleFileCopyToolOutput

final class AppleFileCopyOutputPipe: @unchecked Sendable {
    struct Metrics: Sendable {
        let pendingBytes: UInt64
        let totalBytesEnqueued: UInt64
    }

    private struct Entry: Sendable {
        let output: AppleFileCopyToolOutput
        let byteCount: UInt64
    }

    private actor State {
        enum Reservation {
            case accepted
            case backpressured
            case failed
        }

        private var pendingBytes: UInt64 = 0
        private var totalBytesEnqueued: UInt64 = 0
        private var writerFailed = false

        func reserve(_ byteCount: UInt64, limit: UInt64) -> Reservation {
            guard !writerFailed else { return .failed }
            // The native producer checks the existing queue before appending,
            // so one final 64 KiB frame may take it just past 20 MiB.
            guard pendingBytes <= limit else { return .backpressured }
            let (newPending, pendingOverflow) = pendingBytes.addingReportingOverflow(byteCount)
            let (newTotal, totalOverflow) = totalBytesEnqueued.addingReportingOverflow(byteCount)
            guard !pendingOverflow, !totalOverflow else {
                writerFailed = true
                return .failed
            }
            pendingBytes = newPending
            totalBytesEnqueued = newTotal
            return .accepted
        }

        func didSend(_ byteCount: UInt64) {
            pendingBytes = pendingBytes >= byteCount ? pendingBytes - byteCount : 0
        }

        func fail() {
            writerFailed = true
        }

        func metrics() -> Metrics {
            Metrics(
                pendingBytes: pendingBytes,
                totalBytesEnqueued: totalBytesEnqueued
            )
        }
    }

    private static let pendingByteLimit: UInt64 = 20 * 1_024 * 1_024
    private static let backpressurePollNanoseconds: UInt64 = 350_000_000

    private let state: State
    private let continuation: AsyncStream<Entry>.Continuation
    private let writer: Task<Void, Error>

    init(
        receive: @escaping @Sendable (AppleFileCopyToolOutput) async throws -> Void
    ) {
        let state = State()
        let (stream, continuation) = AsyncStream.makeStream(
            of: Entry.self,
            bufferingPolicy: .unbounded
        )
        self.state = state
        self.continuation = continuation
        writer = Task {
            do {
                for await entry in stream {
                    try Task.checkCancellation()
                    try await receive(entry.output)
                    await state.didSend(entry.byteCount)
                }
            } catch {
                await state.fail()
                throw error
            }
        }
    }

    deinit {
        continuation.finish()
        writer.cancel()
    }

    func send(_ output: AppleFileCopyToolOutput) async throws {
        let entry = Entry(output: output, byteCount: Self.byteCount(of: output))
        while true {
            try Task.checkCancellation()
            switch await state.reserve(entry.byteCount, limit: Self.pendingByteLimit) {
            case .accepted:
                switch continuation.yield(entry) {
                case .enqueued:
                    return
                case .dropped, .terminated:
                    await state.fail()
                    throw AppleFileTransferServiceError.senderFailed
                @unknown default:
                    await state.fail()
                    throw AppleFileTransferServiceError.senderFailed
                }
            case .backpressured:
                try await Task.sleep(nanoseconds: Self.backpressurePollNanoseconds)
            case .failed:
                throw AppleFileTransferServiceError.senderFailed
            }
        }
    }

    func metrics() async -> Metrics {
        await state.metrics()
    }

    func finish() async throws {
        continuation.finish()
        try await writer.value
    }

    func cancel() async {
        continuation.finish()
        writer.cancel()
        _ = try? await writer.value
    }

    private static func byteCount(of output: AppleFileCopyToolOutput) -> UInt64 {
        switch output {
        case .frame(let message), .itemInfo(let message):
            // Native pending accounting includes the 4-byte tool length and
            // 2-byte tool command that wrap each wire frame.
            return UInt64(message.count) + 6
        case .finished:
            return 6
        }
    }
}
