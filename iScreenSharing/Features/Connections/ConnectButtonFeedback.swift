import SwiftUI

extension View {
    @ViewBuilder
    func nativeConnectButtonFeedback() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
                .modifier(MacOS26ConnectButtonPressModifier())
        } else {
            self
        }
    }
}

@available(macOS 26.0, *)
private struct MacOS26ConnectButtonPressModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @GestureState private var isPointerDown = false

    func body(content: Content) -> some View {
        let isPressed = isEnabled && isPointerDown
        content
            .brightness(isPressed ? -0.14 : 0)
            .scaleEffect(isPressed && !reduceMotion ? 0.97 : 1)
            .animation(
                isPressed ? nil : .easeOut(duration: 0.12),
                value: isPressed
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPointerDown) { _, state, _ in
                        state = true
                    }
            )
    }
}
