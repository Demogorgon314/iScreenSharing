import struct ScreenSharingProtocol.AppleCursorImage
import SwiftUI
import UIKit

struct MobileVideoCanvasView: UIViewRepresentable {
    let stream: AppleVideoStream
    let input: AppleInputController?
    let cursors: AppleCursorStore?
    @Binding var requestsKeyboard: Bool
    var showsMetalPerformanceHUD = false

    func makeUIView(context: Context) -> MobileVideoCanvasUIView {
        let view = MobileVideoCanvasUIView(stream: stream, input: input, cursors: cursors)
        view.setShowsMetalPerformanceHUD(showsMetalPerformanceHUD)
        return view
    }

    func updateUIView(_ view: MobileVideoCanvasUIView, context: Context) {
        view.update(stream: stream, input: input, cursors: cursors)
        view.setKeyboardVisible(requestsKeyboard)
        view.setShowsMetalPerformanceHUD(showsMetalPerformanceHUD)
    }

    static func dismantleUIView(_ view: MobileVideoCanvasUIView, coordinator: ()) {
        view.close()
    }
}

@MainActor
private final class MobileVideoDisplayLinkTarget: NSObject, CAMetalDisplayLinkDelegate {
    weak var view: MobileVideoCanvasUIView?

    init(view: MobileVideoCanvasUIView) {
        self.view = view
    }

    nonisolated func metalDisplayLink(
        _ link: CAMetalDisplayLink,
        needsUpdate update: CAMetalDisplayLink.Update
    ) {
        // The link is registered exclusively on the main run loop below, so
        // its delegate callback shares the view's MainActor isolation.
        MainActor.assumeIsolated {
            view?.metalDisplayLinkDidFire(update)
        }
    }
}

@MainActor
final class MobileVideoCanvasUIView: UIView, UIKeyInput {
    private struct ScheduledDragPoint {
        let point: MobileRemotePointerState.Point
        let sendAt: TimeInterval
    }

    private var stream: AppleVideoStream
    private var input: AppleInputController?
    private var cursors: AppleCursorStore?
    private let metalLayer: AppleNV24MetalLayer?
    private let cursorLayer = CALayer()
    private var cursorObserver: UUID?
    private var displayLink: CAMetalDisplayLink?
    private var displayLinkTarget: MobileVideoDisplayLinkTarget?
    private var previousTargetPresentationTimestamp: TimeInterval?
    private var displayScheduler = AppleVideoDisplayScheduler(
        queueCapacity: 4,
        presentsOnEnqueue: false,
        preservesEnqueuedBatches: true,
        presentsEarlyWhenBacklogged: true,
        coalescesDueBatches: true
    )
    private var pointerState = MobileRemotePointerState()
    private var dragPreviousLocation: CGPoint?
    private var dragInputTask: Task<Void, Never>?
    private var scheduledDragPoints = [ScheduledDragPoint]()
    private var dragReleasePoint: MobileRemotePointerState.Point?
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
            self.stream = stream
            displayScheduler.reset()
            updateCursorPosition(pointerState.currentPoint(canvas: stream.canvas))
            setNeedsLayout()
        }
    }

    func setShowsMetalPerformanceHUD(_ enabled: Bool) {
        guard metalLayer?.showsDeveloperHUD != enabled else { return }
        metalLayer?.showsDeveloperHUD = enabled
    }

    func close() {
        if let cursorObserver { cursors?.removeObserver(cursorObserver) }
        cursorObserver = nil
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
        previousTargetPresentationTimestamp = nil
        displayScheduler.reset()
        dragInputTask?.cancel()
        dragInputTask = nil
        scheduledDragPoints.removeAll(keepingCapacity: false)
        dragReleasePoint = nil
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
        enqueueForPresentation(frames)
    }

    private func enqueueForPresentation(_ frames: AppleVideoFrameStore.FrameBatch) {
        let mainDeliveredAt = CACurrentMediaTime()
        for frame in frames.values {
            stream.performance.recordFrameDelivery(
                frameKey: frame.sequence,
                accessUnitTiming: frame.accessUnitTiming,
                decodeEnteredAt: frame.decodeEnteredAt,
                decoderSubmittedAt: frame.decoderSubmittedAt,
                decoderOutputAt: frame.decoderOutputAt,
                playbackHandledAt: frame.playbackHandledAt,
                mainDeliveredAt: mainDeliveredAt,
                presentationTime: frame.presentationTime
            )
        }
        if let update = displayScheduler.enqueue(frames) {
            applyAndPresent(update)
        }
    }

    private func configureDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
        previousTargetPresentationTimestamp = nil
        displayScheduler.invalidateDisplayTarget()
        guard window != nil, let metalLayer else { return }
        let target = MobileVideoDisplayLinkTarget(view: self)
        let displayLink = CAMetalDisplayLink(metalLayer: metalLayer)
        let maximumFramesPerSecond = Float(max(1, window?.screen.maximumFramesPerSecond ?? 60))
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: min(30, maximumFramesPerSecond),
            maximum: maximumFramesPerSecond,
            preferred: maximumFramesPerSecond
        )
        displayLink.preferredFrameLatency = 1
        displayLink.delegate = target
        displayLink.add(to: .main, forMode: .common)
        displayLinkTarget = target
        self.displayLink = displayLink
        enqueueCurrentFrames()
    }

    fileprivate func metalDisplayLinkDidFire(_ metalUpdate: CAMetalDisplayLink.Update) {
        let callbackTime = CACurrentMediaTime()
        for frames in stream.frames.drainLogicalFrameBatches() {
            enqueueForPresentation(frames)
        }
        let period = previousTargetPresentationTimestamp.map {
            metalUpdate.targetPresentationTimestamp - $0
        } ?? 0
        previousTargetPresentationTimestamp = metalUpdate.targetPresentationTimestamp
        stream.performance.recordDisplayLink(
            lead: metalUpdate.targetTimestamp - callbackTime,
            period: period
        )
        let update = displayScheduler.displayLinkDidFire(
            targetTimestamp: metalUpdate.targetPresentationTimestamp,
            period: period
        )
        applyAndPresent(update, drawable: metalUpdate.drawable)
    }

    private func applyAndPresent(
        _ update: AppleVideoDisplayScheduler.DisplayUpdate,
        drawable: CAMetalDrawable? = nil
    ) {
        if !update.frames.isEmpty, let metalLayer {
            stream.performance.recordSchedulerSelection(
                frameKeys: update.frames.values.map(\.sequence),
                selectedAt: CACurrentMediaTime()
            )
            for (tileIndex, frame) in update.frames {
                metalLayer.update(frame, at: tileIndex)
            }
            updateLayout()
        }
        guard update.requiresPresentation, let metalLayer else { return }
        let didPresent: Bool
        if let drawable {
            didPresent = metalLayer.present(
                drawable: drawable,
                targetTimestamp: update.targetTimestamp,
                displayPeriod: update.displayPeriod,
                isDisplayLinkTriggered: update.trigger == .displayLinkTick
            )
        } else {
            didPresent = metalLayer.present(
                targetTimestamp: update.targetTimestamp,
                displayPeriod: update.displayPeriod,
                isDisplayLinkTriggered: update.trigger == .displayLinkTick
            )
        }
        if !didPresent {
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
            startDragInput(at: point)
        case .changed:
            let previous = dragPreviousLocation ?? location
            dragPreviousLocation = location
            let previousPoint = pointerState.currentPoint(canvas: stream.canvas)
            let point = pointerState.move(
                by: CGPoint(x: location.x - previous.x, y: location.y - previous.y),
                canvas: stream.canvas,
                bounds: bounds
            )
            updateCursorPosition(point)
            scheduleDragPath(from: previousPoint, to: point)
        case .ended, .cancelled, .failed:
            if recognizer.state == .ended, let previous = dragPreviousLocation {
                let previousPoint = pointerState.currentPoint(canvas: stream.canvas)
                let finalPoint = pointerState.move(
                    by: CGPoint(x: location.x - previous.x, y: location.y - previous.y),
                    canvas: stream.canvas,
                    bounds: bounds
                )
                updateCursorPosition(finalPoint)
                scheduleDragPath(from: previousPoint, to: finalPoint)
            }
            dragPreviousLocation = nil
            let point = pointerState.currentPoint(canvas: stream.canvas)
            finishDragInput(at: point)
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

    private func scheduleDragPath(
        from start: MobileRemotePointerState.Point,
        to end: MobileRemotePointerState.Point
    ) {
        let points = MobileRemotePointerPath.interpolatedPoints(from: start, to: end)
        guard !points.isEmpty else { return }
        let now = CACurrentMediaTime()
        let segmentStart = max(now, scheduledDragPoints.last?.sendAt ?? now)
        let segmentDuration = 1.0 / 60.0
        for (index, point) in points.enumerated() {
            scheduledDragPoints.append(ScheduledDragPoint(
                point: point,
                sendAt: segmentStart
                    + segmentDuration * Double(index + 1) / Double(points.count)
            ))
        }
    }

    private func startDragInput(at point: MobileRemotePointerState.Point) {
        dragInputTask?.cancel()
        scheduledDragPoints.removeAll(keepingCapacity: true)
        dragReleasePoint = nil
        let predecessor = inputTail
        let input = input
        let task = Task { @MainActor [weak self] in
            await predecessor.value
            guard let self, let input, !Task.isCancelled else { return }
            await input.pointer(
                buttons: AppleInputController.leftButton,
                x: point.x,
                y: point.y,
                clickCount: 1
            )
            while !Task.isCancelled {
                guard let scheduled = self.scheduledDragPoints.first else {
                    if let releasePoint = self.dragReleasePoint {
                        await input.pointer(
                            buttons: 0,
                            x: releasePoint.x,
                            y: releasePoint.y,
                            clickCount: 1
                        )
                        self.dragReleasePoint = nil
                        return
                    }
                    do {
                        try await Task.sleep(nanoseconds: 1_000_000)
                    } catch {
                        return
                    }
                    continue
                }
                let delay = scheduled.sendAt - CACurrentMediaTime()
                if delay > 0 {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    } catch {
                        return
                    }
                }
                guard !Task.isCancelled, !self.scheduledDragPoints.isEmpty else { return }
                self.scheduledDragPoints.removeFirst()
                await input.pointer(
                    buttons: AppleInputController.leftButton,
                    x: scheduled.point.x,
                    y: scheduled.point.y,
                    clickCount: 1
                )
            }
        }
        dragInputTask = task
        inputTail = task
    }

    private func finishDragInput(at point: MobileRemotePointerState.Point) {
        dragReleasePoint = point
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
