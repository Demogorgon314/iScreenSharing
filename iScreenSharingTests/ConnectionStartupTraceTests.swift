import XCTest
@testable import iScreenSharing

final class ConnectionStartupTraceTests: XCTestCase {
    func testOverlappingBranchesUseTheirOwnAnchorsAndPresentationEventTime() throws {
        let recorder = StartupTimingRecorder(time: 100)
        let trace = recorder.makeTrace()
        trace.record(.videoStarted, index: 0, at: 100.1)
        trace.record(.audioStarted, at: 100.2)
        trace.record(.firstPacket, index: 0, since: .init(.videoStarted, index: 0), at: 100.3)
        trace.record(.audioReady, since: .init(.audioStarted), at: 100.6)
        trace.record(.firstFramePublished, index: 0, at: 100.4)
        recorder.setTime(101) // The drawable callback arrives after its presentation time.
        trace.record(.firstPresented, index: 0, since: .init(.firstFramePublished, index: 0), at: 100.5)

        let audio = try XCTUnwrap(recorder.entry(.audioReady))
        let presented = try XCTUnwrap(recorder.entry(.firstPresented, index: 0))
        XCTAssertEqual(try XCTUnwrap(audio.durationMilliseconds), 400, accuracy: 0.001)
        XCTAssertEqual(presented.elapsedMilliseconds, 500, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(presented.durationMilliseconds), 100, accuracy: 0.001)
    }

    func testDuplicateCallbacksAndMediaRestartsKeepFirstObservationPerDisplay() async throws {
        let recorder = StartupTimingRecorder()
        let trace = recorder.makeTrace()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { trace.record(.firstPresented, index: 0, at: 1) }
            }
        }
        trace.record(.firstPresented, index: 0, at: 2)
        trace.record(.firstPresented, index: 1, at: 3)

        let presentations = recorder.entries.filter { $0.event.stage == .firstPresented }
        XCTAssertEqual(presentations.count, 2)
        XCTAssertEqual(recorder.entry(.firstPresented, index: 0)?.elapsedMilliseconds, 1_000)
        XCTAssertEqual(recorder.entry(.firstPresented, index: 1)?.elapsedMilliseconds, 3_000)
    }

    func testMissingOrInvalidAnchorDoesNotInventDuration() throws {
        let recorder = StartupTimingRecorder(time: 10)
        let trace = recorder.makeTrace()
        trace.record(.firstPacket, index: 0, at: .nan)
        trace.record(.firstPacket, index: 0, at: 9)
        XCTAssertNil(recorder.entry(.firstPacket, index: 0))
        trace.record(.firstPacket, index: 0, since: .init(.videoStarted, index: 0), at: 11)
        trace.record(.audioStarted, at: 13)
        trace.record(.audioReady, since: .init(.audioStarted), at: 12)

        XCTAssertNil(try XCTUnwrap(recorder.entry(.firstPacket, index: 0)).durationMilliseconds)
        XCTAssertNil(try XCTUnwrap(recorder.entry(.audioReady)).durationMilliseconds)
    }

    func testTerminationSuppressesLateCallbacksWithoutAffectingReconnect() {
        let recorder = StartupTimingRecorder()
        let first = recorder.makeTrace()
        first.finish(.cancelled)
        first.finish(.closed)
        first.record(.firstPresented, index: 0)
        let second = recorder.makeTrace()
        second.record(.firstPresented, index: 0)

        XCTAssertEqual(recorder.entries.filter { $0.connectionID == first.connectionID }.map(\.event.stage), [
            .signInStarted, .cancelled,
        ])
        XCTAssertEqual(recorder.entries.filter { $0.connectionID == second.connectionID }.map(\.event.stage), [
            .signInStarted, .firstPresented,
        ])
    }

    func testTaskLocalContextIsIsolatedAndCanBeRetainedAcrossCallbackBoundary() async {
        let first = StartupTimingRecorder().makeTrace()
        let second = StartupTimingRecorder().makeTrace()
        await withTaskGroup(of: Void.self) { group in
            for trace in [first, second] {
                group.addTask {
                    let retained = await ConnectionStartupTrace.$current.withValue(trace) {
                        await Task.yield()
                        return ConnectionStartupTrace.current
                    }
                    XCTAssertTrue(retained === trace)
                    XCTAssertNil(ConnectionStartupTrace.current)
                }
            }
        }
        XCTAssertNil(ConnectionStartupTrace.current)
    }
}

final class StartupTimingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval
    private var recordedEntries = [ConnectionStartupTrace.Entry]()

    init(time: TimeInterval = 0) { self.time = time }

    var entries: [ConnectionStartupTrace.Entry] { lock.withLock { recordedEntries } }

    func entry(_ stage: ConnectionStartupTrace.Stage, index: Int? = nil) -> ConnectionStartupTrace.Entry? {
        entries.first { $0.event == .init(stage, index: index) }
    }

    func setTime(_ time: TimeInterval) { lock.withLock { self.time = time } }

    func advance(by interval: TimeInterval) { lock.withLock { time += interval } }

    func makeTrace() -> ConnectionStartupTrace {
        ConnectionStartupTrace(
            clock: { self.lock.withLock { self.time } },
            emit: { entry in self.lock.withLock { self.recordedEntries.append(entry) } }
        )
    }
}
