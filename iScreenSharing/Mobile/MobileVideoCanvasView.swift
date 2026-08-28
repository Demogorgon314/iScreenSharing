import SwiftUI
import UIKit

struct MobileVideoCanvasView: UIViewRepresentable {
    let stream: AppleVideoStream
    let input: AppleInputController?
    @Binding var requestsKeyboard: Bool

    func makeUIView(context: Context) -> MobileVideoCanvasUIView {
        MobileVideoCanvasUIView(stream: stream, input: input)
    }

    func updateUIView(_ view: MobileVideoCanvasUIView, context: Context) {
        view.update(stream: stream, input: input)
        view.setKeyboardVisible(requestsKeyboard)
    }

    static func dismantleUIView(_ view: MobileVideoCanvasUIView, coordinator: ()) {
        view.close()
    }
}

@MainActor
final class MobileVideoCanvasUIView: UIView, UIKeyInput {
    private var stream: AppleVideoStream
    private var input: AppleInputController?
    private let metalLayer: AppleNV24MetalLayer?
    private var frameObserver: UUID?
    private var lastRemotePoint: (x: Int, y: Int)?
    private var inputTail = Task<Void, Never> {}

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    init(stream: AppleVideoStream, input: AppleInputController?) {
        self.stream = stream
        self.input = input
        if let context = AppleNV24MetalContext() {
            metalLayer = AppleNV24MetalLayer(
                context: context,
                synchronizesPresentation: true,
                performance: stream.performance
            )
        } else {
            metalLayer = nil
        }
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        if let metalLayer { layer.addSublayer(metalLayer) }
        installGestures()
        observeFrames()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let metalLayer else { return }
        metalLayer.frame = bounds
        metalLayer.contentsScale = window?.screen.scale ?? UIScreen.main.scale
        updateLayout()
        _ = metalLayer.present()
    }

    func update(stream: AppleVideoStream, input: AppleInputController?) {
        self.input = input
        guard self.stream !== stream else { return }
        if let frameObserver { self.stream.frames.removeObserver(frameObserver) }
        self.stream = stream
        observeFrames()
        setNeedsLayout()
    }

    func close() {
        if let frameObserver { stream.frames.removeObserver(frameObserver) }
        frameObserver = nil
        inputTail.cancel()
        metalLayer?.prepareForInactivity()
    }

    func setKeyboardVisible(_ visible: Bool) {
        if visible, !isFirstResponder {
            becomeFirstResponder()
        } else if !visible, isFirstResponder {
            resignFirstResponder()
        }
    }

    func insertText(_ text: String) {
        for scalar in text.unicodeScalars {
            let symbol: UInt32
            switch scalar.value {
            case 0x09: symbol = 0xff09
            case 0x0a, 0x0d: symbol = 0xff0d
            default:
                symbol = scalar.value <= 0xff ? scalar.value : 0x0100_0000 | scalar.value
            }
            sendKey(symbol: symbol)
        }
    }

    func deleteBackward() {
        sendKey(symbol: 0xff08)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key,
                  let symbol = Self.keySymbol(for: key) else { continue }
            handled = true
            enqueueInput { input in
                await input.key(
                    isDown: true,
                    symbol: symbol,
                    keyCode: UInt16(truncatingIfNeeded: key.keyCode.rawValue)
                )
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key,
                  let symbol = Self.keySymbol(for: key) else { continue }
            handled = true
            enqueueInput { input in
                await input.key(
                    isDown: false,
                    symbol: symbol,
                    keyCode: UInt16(truncatingIfNeeded: key.keyCode.rawValue)
                )
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    private func observeFrames() {
        frameObserver = stream.frames.addObserver { [weak self] frames in
            guard let self, let metalLayer = self.metalLayer else { return }
            for (tileIndex, frame) in frames {
                metalLayer.update(frame, at: tileIndex)
            }
            self.updateLayout()
            _ = metalLayer.present()
        }
    }

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTap(_:)))
        let drag = UIPanGestureRecognizer(target: self, action: #selector(didDrag(_:)))
        drag.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(didScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        let rightClick = UITapGestureRecognizer(target: self, action: #selector(didRightClick(_:)))
        rightClick.numberOfTouchesRequired = 2
        tap.require(toFail: drag)
        tap.require(toFail: rightClick)
        addGestureRecognizer(tap)
        addGestureRecognizer(drag)
        addGestureRecognizer(scroll)
        addGestureRecognizer(rightClick)
        if #available(iOS 13.4, *) {
            addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(didHover(_:))))
        }
    }

    @objc private func didTap(_ recognizer: UITapGestureRecognizer) {
        guard let point = remotePoint(for: recognizer.location(in: self)) else { return }
        lastRemotePoint = point
        enqueueInput { input in
            await input.pointer(buttons: AppleInputController.leftButton, x: point.x, y: point.y, clickCount: 1)
            await input.pointer(buttons: 0, x: point.x, y: point.y, clickCount: 1)
        }
    }

    @objc private func didDrag(_ recognizer: UIPanGestureRecognizer) {
        let isEnding = recognizer.state == .ended || recognizer.state == .cancelled
        guard let point = remotePoint(for: recognizer.location(in: self))
            ?? (isEnding ? lastRemotePoint : nil) else { return }
        lastRemotePoint = point
        let buttons: UInt8 = recognizer.state == .ended || recognizer.state == .cancelled
            ? 0
            : AppleInputController.leftButton
        enqueueInput { input in
            await input.pointer(buttons: buttons, x: point.x, y: point.y, clickCount: 1)
        }
    }

    @objc private func didScroll(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .changed,
              let point = lastRemotePoint ?? remotePoint(for: recognizer.location(in: self)) else { return }
        let translation = recognizer.translation(in: self)
        let vertical = Int(-translation.y / 12)
        let horizontal = Int(translation.x / 12)
        guard vertical != 0 || horizontal != 0 else { return }
        recognizer.setTranslation(.zero, in: self)
        enqueueInput { input in
            await input.scroll(
                verticalTicks: vertical,
                horizontalTicks: horizontal,
                x: point.x,
                y: point.y
            )
        }
    }

    @objc private func didRightClick(_ recognizer: UITapGestureRecognizer) {
        guard let point = remotePoint(for: recognizer.location(in: self)) else { return }
        lastRemotePoint = point
        enqueueInput { input in
            await input.pointer(buttons: AppleInputController.rightButton, x: point.x, y: point.y, clickCount: 1)
            await input.pointer(buttons: 0, x: point.x, y: point.y, clickCount: 1)
        }
    }

    @objc private func didHover(_ recognizer: UIHoverGestureRecognizer) {
        guard let point = remotePoint(for: recognizer.location(in: self)) else { return }
        lastRemotePoint = point
        enqueueInput { input in
            await input.pointer(buttons: 0, x: point.x, y: point.y)
        }
    }

    private func remotePoint(for location: CGPoint) -> (x: Int, y: Int)? {
        AppleVideoCanvasLayout.remotePoint(location: location, canvas: stream.canvas, bounds: bounds)
    }

    private func sendKey(symbol: UInt32) {
        enqueueInput { input in
            await input.key(isDown: true, symbol: symbol)
            await input.key(isDown: false, symbol: symbol)
        }
    }

    private func enqueueInput(
        _ operation: @escaping @Sendable (AppleInputController) async -> Void
    ) {
        let predecessor = inputTail
        let input = input
        inputTail = Task {
            await predecessor.value
            guard !Task.isCancelled, let input else { return }
            await operation(input)
        }
    }

    private static func keySymbol(for key: UIKey) -> UInt32? {
        switch key.keyCode {
        case .keyboardEscape: 0xff1b
        case .keyboardTab: 0xff09
        case .keyboardReturnOrEnter, .keypadEnter: 0xff0d
        case .keyboardDeleteOrBackspace: 0xff08
        case .keyboardDeleteForward: 0xffff
        case .keyboardLeftArrow: 0xff51
        case .keyboardUpArrow: 0xff52
        case .keyboardRightArrow: 0xff53
        case .keyboardDownArrow: 0xff54
        case .keyboardHome: 0xff50
        case .keyboardEnd: 0xff57
        case .keyboardPageUp: 0xff55
        case .keyboardPageDown: 0xff56
        case .keyboardLeftShift, .keyboardRightShift: 0xffe1
        case .keyboardLeftControl, .keyboardRightControl: 0xffe3
        case .keyboardLeftAlt, .keyboardRightAlt: 0xffe9
        case .keyboardLeftGUI, .keyboardRightGUI: 0xffeb
        case .keyboardCapsLock: 0xffe5
        default:
            key.charactersIgnoringModifiers.unicodeScalars.first.map { scalar in
                scalar.value <= 0xff ? scalar.value : 0x0100_0000 | scalar.value
            }
        }
    }

    private func updateLayout() {
        guard let metalLayer else { return }
        let canvas = stream.canvas
        metalLayer.update(
            layouts: AppleVideoCanvasLayout.tiles(canvas: canvas, bounds: bounds),
            fullCanvasLayout: AppleVideoCanvasLayout.fullCanvas(canvas: canvas, bounds: bounds),
            canvasSize: CGSize(width: canvas.width, height: canvas.height),
            bounds: bounds
        )
    }
}
