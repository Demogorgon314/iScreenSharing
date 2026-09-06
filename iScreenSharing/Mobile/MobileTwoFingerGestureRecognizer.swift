#if os(iOS)
import UIKit
import UIKit.UIGestureRecognizerSubclass

@MainActor
final class MobileTwoFingerGestureRecognizer: UIGestureRecognizer {
    private var trackedTouches = [UITouch]()
    private var gesture = MobileTwoFingerGestureState()
    private(set) var movement: MobileTwoFingerGestureState.Update?
    private(set) var recognizedOnEnd = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        trackedTouches.append(contentsOf: touches)
        guard trackedTouches.count <= 2 else {
            state = state == .possible ? .failed : .cancelled
            return
        }
        if trackedTouches.count == 2 {
            gesture.begin(first: trackedTouches[0].location(in: view), second: trackedTouches[1].location(in: view))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouches.count == 2 else { return }
        movement = gesture.update(
            first: trackedTouches[0].location(in: view), second: trackedTouches[1].location(in: view),
            timestamp: max(trackedTouches[0].timestamp, trackedTouches[1].timestamp)
        )
        if movement != nil { state = state == .possible ? .began : .changed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouches.count == 2 else {
            state = .failed
            return
        }
        movement = gesture.update(
            first: trackedTouches[0].location(in: view), second: trackedTouches[1].location(in: view),
            timestamp: max(trackedTouches[0].timestamp, trackedTouches[1].timestamp)
        )
        guard movement != nil else {
            state = .failed
            return
        }
        recognizedOnEnd = state == .possible
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        super.reset()
        trackedTouches.removeAll()
        gesture = MobileTwoFingerGestureState()
        movement = nil
        recognizedOnEnd = false
    }
}
#endif
