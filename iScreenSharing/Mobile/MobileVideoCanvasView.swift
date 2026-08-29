import SwiftUI
import UIKit

struct MobileVideoCanvasView: UIViewRepresentable {
    let stream: AppleVideoStream
    let input: AppleInputController?
    let cursors: AppleCursorStore?
    @Binding var requestsKeyboard: Bool

    func makeUIView(context: Context) -> MobileVideoCanvasUIView {
        MobileVideoCanvasUIView(stream: stream, input: input, cursors: cursors)
    }

    func updateUIView(_ view: MobileVideoCanvasUIView, context: Context) {
        view.update(stream: stream, input: input, cursors: cursors)
        view.setKeyboardVisible(requestsKeyboard)
    }

    static func dismantleUIView(_ view: MobileVideoCanvasUIView, coordinator: ()) {
        view.close()
    }
}

@MainActor
private final class MobileVideoDisplayLinkTarget: NSObject {
    weak var view: MobileVideoCanvasUIView?

    init(view: MobileVideoCanvasUIView) {
        self.view = view
    }

    @objc func displayLinkDidFire(_ displayLink: CADisplayLink) {
        view?.displayLinkDidFire(displayLink)
    }
}

@MainActor
final class MobileVideoCanvasUIView: UIView, UIKeyInput {
    private var stream: AppleVideoStream
    private var input: AppleInputController?
    private var cursors: AppleCursorStore?
    private let metalLayer: AppleNV24MetalLayer?
    private let cursorLayer = CALayer()
    private var frameObserver: UUID?
    private var cursorObserver: UUID?
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: MobileVideoDisplayLinkTarget?
    private var displayScheduler = AppleVideoDisplayScheduler()
    private var pointerState = MobileRemotePointerState()
    private var dragPreviousLocation: CGPoint?
    private var cursorHotspot = CGPoint.zero
    private var inputTail = Task<Void, Never> {}

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    init(stream: AppleVideoStream, input: AppleInputController?, cursors: AppleCursorStore?) {
        self.stream = stream
        self.input = input
        self.cursors = cursors
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
        cursorLayer.isHidden = true
        cursorLayer.contentsGravity = .resize
        layer.addSublayer(cursorLayer)
        installGestures()
        observeFrames()
        observeCursor()
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
        updateCursorPosition(pointerState.currentPoint(canvas: stream.canvas))
        displayScheduler.markNeedsPresentation()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        configureDisplayLink()
    }

    func update(
        stream: AppleVideoStream,
        input: AppleInputController?,
        cursors: AppleCursorStore?
    ) {
        self.input = input
        if self.cursors !== cursors {
            if let cursorObserver { self.cursors?.removeObserver(cursorObserver) }
            self.cursors = cursors
            observeCursor()
        }
        if self.stream !== stream {
            if let frameObserver { self.stream.frames.removeObserver(frameObserver) }
            self.stream = stream
            displayScheduler.reset()
            updateCursorPosition(pointerState.currentPoint(canvas: stream.canvas))
            observeFrames()
            setNeedsLayout()
        }
    }

    func close() {
        if let frameObserver { stream.frames.removeObserver(frameObserver) }
        if let cursorObserver { cursors?.removeObserver(cursorObserver) }
        frameObserver = nil
        cursorObserver = nil
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
        displayScheduler.reset()
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
            guard let self else { return }
            if let update = self.displayScheduler.enqueue(frames) {
                self.applyAndPresent(update)
            }
        }
        enqueueCurrentFrames()
    }

    private func observeCursor() {
        cursorObserver = cursors?.addObserver { [weak self] image in
            self?.applyCursor(image)
        }
        applyCursor(cursors?.currentImage())
    }

    private func enqueueCurrentFrames() {
        let frames = ([AppleVideoFrameStore.fullCanvasIndex] + Array(0..<stream.canvas.tileCount))
            .reduce(into: AppleVideoFrameStore.FrameBatch()) { result, tileIndex in
                result[tileIndex] = stream.frames.storedFrame(at: tileIndex)
            }
        if let update = displayScheduler.enqueue(frames) {
            applyAndPresent(update)
        }
    }

    private func configureDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
        displayScheduler.invalidateDisplayTarget()
        guard window != nil, metalLayer != nil else { return }
        let target = MobileVideoDisplayLinkTarget(view: self)
        let displayLink = CADisplayLink(target: target, selector: #selector(target.displayLinkDidFire(_:)))
        let maximumFramesPerSecond = Float(max(1, window?.screen.maximumFramesPerSecond ?? 60))
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: maximumFramesPerSecond,
            maximum: maximumFramesPerSecond,
            preferred: maximumFramesPerSecond
        )
        displayLink.add(to: .main, forMode: .common)
        displayLinkTarget = target
        self.displayLink = displayLink
        enqueueCurrentFrames()
    }

    fileprivate func displayLinkDidFire(_ displayLink: CADisplayLink) {
        let period = displayLink.targetTimestamp - displayLink.timestamp
        applyAndPresent(displayScheduler.displayLinkDidFire(
            targetTimestamp: displayLink.targetTimestamp,
            period: period
        ))
    }

    private func applyAndPresent(_ update: AppleVideoDisplayScheduler.DisplayUpdate) {
        if !update.frames.isEmpty, let metalLayer {
            for (tileIndex, frame) in update.frames {
                metalLayer.update(frame, at: tileIndex)
            }
            updateLayout()
        }
        guard update.requiresPresentation, let metalLayer else { return }
        if !metalLayer.present(
            targetTimestamp: update.targetTimestamp,
            displayPeriod: update.displayPeriod,
            isDisplayLinkTriggered: update.trigger == .displayLinkTick
        ) {
            displayScheduler.presentationDidFail()
        }
    }

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTap(_:)))
        tap.numberOfTouchesRequired = 1
        let move = UIPanGestureRecognizer(target: self, action: #selector(didMovePointer(_:)))
        move.maximumNumberOfTouches = 1
        let drag = UILongPressGestureRecognizer(target: self, action: #selector(didDrag(_:)))
        drag.numberOfTapsRequired = 1
        // After the first tap, the second touch is the mouse-down. Requiring a
        // stationary hold here makes a natural double-tap-and-drag fail before
        // the recognizer can claim the movement.
        drag.minimumPressDuration = 0
        drag.allowableMovement = 18
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(didScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        let rightClick = UITapGestureRecognizer(
            target: self,
            action: #selector(didRightClick(_:))
        )
        rightClick.numberOfTouchesRequired = 2
        move.require(toFail: drag)
        scroll.require(toFail: rightClick)
        addGestureRecognizer(tap)
        addGestureRecognizer(move)
        addGestureRecognizer(drag)
        addGestureRecognizer(scroll)
        addGestureRecognizer(rightClick)
        if #available(iOS 13.4, *) {
            addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(didHover(_:))))
        }
    }

    @objc private func didTap(_ recognizer: UITapGestureRecognizer) {
        let point = pointerState.currentPoint(canvas: stream.canvas)
        enqueueInput { input in
            await input.pointer(buttons: AppleInputController.leftButton, x: point.x, y: point.y, clickCount: 1)
            await input.pointer(buttons: 0, x: point.x, y: point.y, clickCount: 1)
        }
    }

    @objc private func didMovePointer(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .changed else { return }
        let point = pointerState.move(
            by: recognizer.translation(in: self),
            canvas: stream.canvas,
            bounds: bounds
        )
        recognizer.setTranslation(.zero, in: self)
        updateCursorPosition(point)
        sendPointer(buttons: 0, point: point)
    }

    @objc private func didDrag(_ recognizer: UILongPressGestureRecognizer) {
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            dragPreviousLocation = location
            let point = pointerState.currentPoint(canvas: stream.canvas)
            sendPointer(buttons: AppleInputController.leftButton, point: point, clickCount: 1)
        case .changed:
            let previous = dragPreviousLocation ?? location
            dragPreviousLocation = location
            let point = pointerState.move(
                by: CGPoint(x: location.x - previous.x, y: location.y - previous.y),
                canvas: stream.canvas,
                bounds: bounds
            )
            updateCursorPosition(point)
            sendPointer(buttons: AppleInputController.leftButton, point: point, clickCount: 1)
        case .ended, .cancelled, .failed:
            dragPreviousLocation = nil
            let point = pointerState.currentPoint(canvas: stream.canvas)
            sendPointer(buttons: 0, point: point, clickCount: 1)
        default:
            break
        }
    }

    @objc private func didScroll(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .changed else { return }
        let point = pointerState.currentPoint(canvas: stream.canvas)
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
        let point = pointerState.currentPoint(canvas: stream.canvas)
        enqueueInput { input in
            await input.pointer(
                buttons: AppleInputController.rightButton,
                x: point.x,
                y: point.y,
                clickCount: 1
            )
            await input.pointer(buttons: 0, x: point.x, y: point.y, clickCount: 1)
        }
    }

    @objc private func didHover(_ recognizer: UIHoverGestureRecognizer) {
        let location = recognizer.location(in: self)
        guard let point = pointerState.setAbsolute(
            localPoint: location,
            canvas: stream.canvas,
            bounds: bounds
        ) else { return }
        updateCursorPosition(point)
        sendPointer(buttons: 0, point: point)
    }

    private func applyCursor(_ image: AppleCursorImage?) {
        let cursor: (image: CGImage, size: CGSize, hotspot: CGPoint)?
        if let image, let cgImage = Self.cursorImage(from: image) {
            cursor = (
                cgImage,
                CGSize(width: image.width, height: image.height),
                CGPoint(x: image.hotspotX, y: image.hotspotY)
            )
        } else {
            cursor = Self.fallbackCursor()
        }
        guard let cursor else { return }
        cursorHotspot = cursor.hotspot
        cursorLayer.bounds = CGRect(origin: .zero, size: cursor.size)
        cursorLayer.contents = cursor.image
        cursorLayer.contentsScale = window?.screen.scale ?? UIScreen.main.scale
        updateCursorPosition(pointerState.currentPoint(canvas: stream.canvas))
    }

    private func updateCursorPosition(_ point: MobileRemotePointerState.Point) {
        guard cursorLayer.contents != nil,
              let localPoint = AppleVideoCanvasLayout.localPoint(
                  remoteX: point.x,
                  remoteY: point.y,
                  canvas: stream.canvas,
                  bounds: bounds
              ) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.position = CGPoint(
            x: localPoint.x - cursorHotspot.x + cursorLayer.bounds.width / 2,
            y: localPoint.y - cursorHotspot.y + cursorLayer.bounds.height / 2
        )
        cursorLayer.isHidden = false
        CATransaction.commit()
    }

    private func sendPointer(
        buttons: UInt8,
        point: MobileRemotePointerState.Point,
        clickCount: Int = 0
    ) {
        enqueueInput { input in
            await input.pointer(
                buttons: buttons,
                x: point.x,
                y: point.y,
                clickCount: clickCount
            )
        }
    }

    private static func cursorImage(from image: AppleCursorImage) -> CGImage? {
        let (pixelCount, pixelOverflow) = image.width.multipliedReportingOverflow(by: image.height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard image.width > 0, image.height > 0, !pixelOverflow, !byteOverflow,
              image.hotspotX >= 0, image.hotspotX < image.width,
              image.hotspotY >= 0, image.hotspotY < image.height,
              image.rgba.count == byteCount,
              let provider = CGDataProvider(data: image.rgba as CFData) else { return nil }
        return CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func fallbackCursor() -> (image: CGImage, size: CGSize, hotspot: CGPoint)? {
        let size = CGSize(width: 18, height: 24)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 1, y: 1))
            path.addLine(to: CGPoint(x: 1, y: 20))
            path.addLine(to: CGPoint(x: 6, y: 15))
            path.addLine(to: CGPoint(x: 10, y: 23))
            path.addLine(to: CGPoint(x: 14, y: 21))
            path.addLine(to: CGPoint(x: 10, y: 14))
            path.addLine(to: CGPoint(x: 17, y: 14))
            path.close()
            UIColor.white.setFill()
            path.fill()
            UIColor.black.setStroke()
            path.lineWidth = 1.5
            path.lineJoinStyle = .round
            path.stroke()
        }
        guard let cgImage = image.cgImage else { return nil }
        return (cgImage, size, CGPoint(x: 1, y: 1))
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
