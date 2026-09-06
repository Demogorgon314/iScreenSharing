import AVFAudio
import Combine

@MainActor
final class MobileAudioSessionLifecycle {
    private let activate: () throws -> Void
    private let deactivate: () -> Void
    private var availabilityObserver: AnyCancellable?
    private var isActive = false

    init(
        activate: @escaping () throws -> Void = {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        },
        deactivate: @escaping () -> Void = {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    ) {
        self.activate = activate
        self.deactivate = deactivate
    }

    // Availability is published on MainActor by AppleAudioStream. Replacing
    // playback cancels the old subscription before activating its successor.
    func start(availability: AnyPublisher<Bool, Never>) throws {
        stop()
        try activate()
        isActive = true
        availabilityObserver = availability.filter { !$0 }.prefix(1).sink { [weak self] _ in
            self?.stop()
        }
    }

    func stop() {
        availabilityObserver = nil
        guard isActive else { return }
        isActive = false
        deactivate()
    }
}
