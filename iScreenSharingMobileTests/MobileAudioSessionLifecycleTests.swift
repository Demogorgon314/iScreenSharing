import Combine
import XCTest
@testable import iScreenSharingMobile

@MainActor
final class MobileAudioSessionLifecycleTests: XCTestCase {
    func testLateFailureOfReplacedPlaybackCannotDeactivateCurrentAudio() throws {
        let first = CurrentValueSubject<Bool, Never>(true)
        let second = CurrentValueSubject<Bool, Never>(true)
        var activations = 0
        var deactivations = 0
        let lifecycle = MobileAudioSessionLifecycle(
            activate: { activations += 1 }, deactivate: { deactivations += 1 }
        )
        try lifecycle.start(availability: first.eraseToAnyPublisher())
        XCTAssertEqual(deactivations, 0)
        try lifecycle.start(availability: second.eraseToAnyPublisher())
        XCTAssertEqual(activations, 2)
        XCTAssertEqual(deactivations, 1)
        first.send(false)
        XCTAssertEqual(deactivations, 1)
        second.send(false)
        XCTAssertEqual(deactivations, 2)
        second.send(false)
        lifecycle.stop()
        XCTAssertEqual(deactivations, 2)
    }

    func testUnavailablePlaybackImmediatelyReleasesSession() throws {
        let available = CurrentValueSubject<Bool, Never>(false)
        var deactivations = 0
        let lifecycle = MobileAudioSessionLifecycle(activate: {}, deactivate: { deactivations += 1 })
        try lifecycle.start(availability: available.eraseToAnyPublisher())
        XCTAssertEqual(deactivations, 1)
        lifecycle.stop()
        XCTAssertEqual(deactivations, 1)
    }

    func testFailedActivationDoesNotSubscribeOrDeactivateAnUnownedSession() {
        enum Failure: Error { case expected }
        let available = CurrentValueSubject<Bool, Never>(true)
        var deactivations = 0
        let lifecycle = MobileAudioSessionLifecycle(
            activate: { throw Failure.expected }, deactivate: { deactivations += 1 }
        )
        XCTAssertThrowsError(try lifecycle.start(availability: available.eraseToAnyPublisher()))
        available.send(false)
        lifecycle.stop()
        XCTAssertEqual(deactivations, 0)
    }
}
