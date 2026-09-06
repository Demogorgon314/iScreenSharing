import struct ScreenSharingProtocol.AppleCursorImage
import SwiftUI
import UIKit

struct MobileVideoCanvasView: UIViewRepresentable {
    let stream: AppleVideoStream
    let input: AppleInputController?
    let cursors: AppleCursorStore?
    @Binding var requestsKeyboard: Bool
    var showsMetalPerformanceHUD = false
    var supportsPreciseScrolling = false

    func makeUIView(context: Context) -> MobileVideoCanvasUIView {
        let view = MobileVideoCanvasUIView(stream: stream, input: input, cursors: cursors)
        view.setShowsMetalPerformanceHUD(showsMetalPerformanceHUD)
        view.supportsPreciseScrolling = supportsPreciseScrolling
        view.dismissKeyboard = { requestsKeyboard = false }
        return view
    }

    func updateUIView(_ view: MobileVideoCanvasUIView, context: Context) {
        view.update(stream: stream, input: input, cursors: cursors)
        view.setKeyboardVisible(requestsKeyboard)
        view.setShowsMetalPerformanceHUD(showsMetalPerformanceHUD)
        view.supportsPreciseScrolling = supportsPreciseScrolling
        view.dismissKeyboard = { requestsKeyboard = false }
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
final class MobileVideoCanvasUIView: UIView, UIKeyInput, UIGestureRecognizerDelegate {
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
    private var viewport = MobileCanvasViewport()
    private let fitCanvasButton = UIButton(type: .system)
    private var dragPreviousLocation: CGPoint?
    private var dragInputTask: Task<Void, Never>?
    private var scheduledDragPoints = [ScheduledDragPoint]()
    private var dragReleasePoint: MobileRemotePointerState.Point?
    private var cursorHotspot = CGPoint.zero
    private let inputQueue = MobileInputQueue()
    private var dragGeneration: UInt64 = 0
    private var lastSentPointerPoint: MobileRemotePointerState.Point?
    private var acceptsInput = true
    private var interactionBoundsSize: CGSize?
    private var scrollState = MobileScrollState()
    private var keyboardState = MobileKeyboardState()
    private var physicalKeys = [UInt16: UInt32]()
    private let interactionStatus = UILabel()
    private var modifierButtons = [MobileKeyboardModifier: UIButton]()
    private lazy var shortcutBar = makeShortcutBar()
    var supportsPreciseScrolling = false
    var dismissKeyboard: (() -> Void)?

    override var inputAccessoryView: UIView? { shortcutBar }

    override var canBecomeFirstResponder: Bool { true }
    // Three-finger movement belongs to the viewport, not local text undo/redo.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
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
        clipsToBounds = true
        isMultipleTouchEnabled = true
        if let metalLayer { layer.addSublayer(metalLayer) }
        cursorLayer.isHidden = true
        cursorLayer.contentsGravity = .resize
        layer.addSublayer(cursorLayer)
        installGestures()
        observeCursor()
        configureInteractionStatus()
        configureViewportControls()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let interactionBoundsSize, interactionBoundsSize != bounds.size {
            cancelInteractions()
        }
        interactionBoundsSize = bounds.size
        viewport.constrain(base: fittedCanvasFrame, bounds: bounds)
        guard let metalLayer else { return }
        metalLayer.frame = bounds
        metalLayer.contentsScale = window?.screen.scale ?? UIScreen.main.scale
        updateLayout()
        updateCursorPosition(pointerState.currentPoint(canvas: stream.canvas))
        displayScheduler.markNeedsPresentation()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelInteractions() }
        configureDisplayLink()
    }

    func update(
        stream: AppleVideoStream,
        input: AppleInputController?,
        cursors: AppleCursorStore?
    ) {
        if self.input !== input { cancelInteractions() }
        self.input = input
        if self.cursors !== cursors {
            if let cursorObserver { self.cursors?.removeObserver(cursorObserver) }
            self.cursors = cursors
            observeCursor()
        }
        if self.stream !== stream {
            cancelInteractions()
            self.stream = stream
            viewport.constrain(base: fittedCanvasFrame, bounds: bounds)
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
        cancelInteractions()
        acceptsInput = false
        NotificationCenter.default.removeObserver(self)
        if let cursorObserver { cursors?.removeObserver(cursorObserver) }
        cursorObserver = nil
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
        previousTargetPresentationTimestamp = nil
        displayScheduler.reset()
        metalLayer?.prepareForInactivity()
    }

    func setKeyboardVisible(_ visible: Bool) {
        if visible, !isFirstResponder {
            cancelInteractions()
            becomeFirstResponder()
        } else if !visible, isFirstResponder {
            cancelInteractions()
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
        guard acceptsInput else { return }
        var handled = false
        for press in presses {
            guard let key = press.key,
                  let symbol = Self.keySymbol(for: key) else { continue }
            handled = true
            physicalKeys[UInt16(truncatingIfNeeded: key.keyCode.rawValue)] = symbol
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
            physicalKeys.removeValue(forKey: UInt16(truncatingIfNeeded: key.keyCode.rawValue))
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

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        cancelInteractions()
        super.pressesCancelled(presses, with: event)
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
        let twoFinger = MobileTwoFingerGestureRecognizer(target: self, action: #selector(didUseTwoFingers(_:)))
        let panViewport = UIPanGestureRecognizer(target: self, action: #selector(didPanViewport(_:)))
        panViewport.minimumNumberOfTouches = 3
        panViewport.maximumNumberOfTouches = 3
        let rightClick = UITapGestureRecognizer(
            target: self,
            action: #selector(didRightClick(_:))
        )
        rightClick.numberOfTouchesRequired = 2
        move.require(toFail: drag)
        rightClick.require(toFail: twoFinger)
        for recognizer in [tap, move, drag, twoFinger, panViewport, rightClick] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
        if #available(iOS 13.4, *) {
            addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(didHover(_:))))
        }
    }

    @objc private func didTap(_ recognizer: UITapGestureRecognizer) {
        guard acceptsInput else { return }
        let point = pointerState.currentPoint(canvas: stream.canvas)
        enqueueInput { [weak self] input in
            self?.lastSentPointerPoint = point
            await input.pointer(buttons: AppleInputController.leftButton, x: point.x, y: point.y, clickCount: 1)
            await input.pointer(buttons: 0, x: point.x, y: point.y, clickCount: 1)
        }
    }

    @objc private func didMovePointer(_ recognizer: UIPanGestureRecognizer) {
        guard acceptsInput, dragInputTask == nil,
              [.began, .changed, .ended].contains(recognizer.state) else { return }
        let point = pointerState.move(
            by: viewport.unscaledTranslation(recognizer.translation(in: self)),
            canvas: stream.canvas,
            bounds: bounds
        )
        recognizer.setTranslation(.zero, in: self)
        followMovedPointer(point)
        sendPointer(buttons: 0, point: point)
    }

    @objc private func didDrag(_ recognizer: UILongPressGestureRecognizer) {
        guard acceptsInput else { return }
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            let point = pointerState.currentPoint(canvas: stream.canvas)
            startDragInput(at: point)
            dragPreviousLocation = location
        case .changed:
            guard dragInputTask != nil else { return }
            let previous = dragPreviousLocation ?? location
            dragPreviousLocation = location
            let previousPoint = pointerState.currentPoint(canvas: stream.canvas)
            let point = pointerState.move(
                by: viewport.unscaledTranslation(CGPoint(x: location.x - previous.x, y: location.y - previous.y)),
                canvas: stream.canvas,
                bounds: bounds
            )
            followMovedPointer(point)
            scheduleDragPath(from: previousPoint, to: point)
        case .ended:
            guard dragInputTask != nil else { return }
            if let previous = dragPreviousLocation {
                let previousPoint = pointerState.currentPoint(canvas: stream.canvas)
                let finalPoint = pointerState.move(
                    by: viewport.unscaledTranslation(CGPoint(x: location.x - previous.x, y: location.y - previous.y)),
                    canvas: stream.canvas,
                    bounds: bounds
                )
                followMovedPointer(finalPoint)
                scheduleDragPath(from: previousPoint, to: finalPoint)
            }
            dragPreviousLocation = nil
            let point = pointerState.currentPoint(canvas: stream.canvas)
            finishDragInput(at: point)
        case .cancelled, .failed:
            if dragInputTask != nil { cancelInteractions() }
        default:
            break
        }
    }

    @objc private func didUseTwoFingers(_ recognizer: MobileTwoFingerGestureRecognizer) {
        guard acceptsInput else { return }
        if recognizer.state == .began || recognizer.recognizedOnEnd { cancelInteractions() }
        if recognizer.state == .cancelled || recognizer.state == .failed {
            scrollState.reset()
            return
        }
        guard [.began, .changed, .ended].contains(recognizer.state) else { return }
        guard let movement = recognizer.movement else { return }
        switch movement.mode {
        case .zooming:
            viewport.zoom(
                by: movement.scale, around: movement.anchor, translation: movement.translation,
                base: fittedCanvasFrame, bounds: bounds
            )
            refreshViewport()
        case .scrolling:
            sendScroll(translation: movement.translation)
        }
        if recognizer.state == .ended { scrollState.reset() }
    }

    private func sendScroll(translation: CGPoint) {
        let point = pointerState.currentPoint(canvas: stream.canvas)
        let movement = scrollState.consume(translation: translation)
        guard let movement else { return }
        let precise = supportsPreciseScrolling
        enqueueInput { input in
            if precise {
                await input.scroll(event: movement.event, x: point.x, y: point.y)
            } else {
                for _ in 0..<abs(movement.verticalTicks) {
                    await input.scroll(verticalTicks: movement.verticalTicks.signum(), horizontalTicks: 0, x: point.x, y: point.y)
                }
                for _ in 0..<abs(movement.horizontalTicks) {
                    await input.scroll(verticalTicks: 0, horizontalTicks: movement.horizontalTicks.signum(), x: point.x, y: point.y)
                }
            }
        }
    }

    @objc private func didRightClick(_ recognizer: UITapGestureRecognizer) {
        guard acceptsInput else { return }
        if dragInputTask != nil { cancelInteractions() }
        let point = pointerState.currentPoint(canvas: stream.canvas)
        enqueueInput { [weak self] input in
            self?.lastSentPointerPoint = point
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
        guard acceptsInput, dragInputTask == nil else { return }
        let location = recognizer.location(in: self)
        guard let point = pointerState.setAbsolute(
            localPoint: viewport.unproject(location, base: fittedCanvasFrame, bounds: bounds),
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
                  bounds: bounds,
                  viewport: viewport
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
        enqueueInput { [weak self] input in
            self?.lastSentPointerPoint = point
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
        cancelInteractions()
        let generation = dragGeneration
        interactionStatus.text = "  Left button held  "
        interactionStatus.isHidden = false
        UISelectionFeedbackGenerator().selectionChanged()
        let input = input
        let task = inputQueue.enqueue { [weak self] in
            guard let self, let input, !Task.isCancelled else { return }
            self.lastSentPointerPoint = point
            await input.pointer(
                buttons: AppleInputController.leftButton,
                x: point.x,
                y: point.y,
                clickCount: 1
            )
            while !Task.isCancelled {
                guard let scheduled = self.scheduledDragPoints.first else {
                    if let releasePoint = self.dragReleasePoint {
                        self.lastSentPointerPoint = releasePoint
                        await input.pointer(
                            buttons: 0,
                            x: releasePoint.x,
                            y: releasePoint.y,
                            clickCount: 1
                        )
                        if self.dragGeneration == generation {
                            self.dragReleasePoint = nil
                            self.dragInputTask = nil
                            self.interactionStatus.isHidden = true
                        }
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
                self.lastSentPointerPoint = scheduled.point
                await input.pointer(
                    buttons: AppleInputController.leftButton,
                    x: scheduled.point.x,
                    y: scheduled.point.y,
                    clickCount: 1
                )
            }
        }
        dragInputTask = task
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

    @objc private func applicationWillResignActive() {
        acceptsInput = false
        cancelInteractions()
    }

    @objc private func applicationDidBecomeActive() {
        acceptsInput = true
    }

    private func cancelInteractions() {
        let releasesPointer = dragInputTask != nil
        dragGeneration &+= 1
        dragInputTask?.cancel()
        dragInputTask = nil
        scheduledDragPoints.removeAll(keepingCapacity: true)
        dragReleasePoint = nil
        dragPreviousLocation = nil
        scrollState.reset()
        keyboardState.reset()
        updateKeyboardFeedback()
        interactionStatus.isHidden = true
        let keys = physicalKeys.sorted { $0.key < $1.key }
        physicalKeys.removeAll()
        let point = lastSentPointerPoint ?? pointerState.currentPoint(canvas: stream.canvas)
        let input = input
        inputQueue.cancelPending {
            guard let input else { return }
            if releasesPointer {
                await input.pointer(buttons: 0, x: point.x, y: point.y, clickCount: 1)
            }
            for (code, symbol) in keys {
                await input.key(isDown: false, symbol: symbol, keyCode: code)
            }
        }
    }

    private func configureInteractionStatus() {
        interactionStatus.translatesAutoresizingMaskIntoConstraints = false
        interactionStatus.font = .preferredFont(forTextStyle: .caption1)
        interactionStatus.textColor = .white
        interactionStatus.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        interactionStatus.layer.cornerRadius = 7
        interactionStatus.clipsToBounds = true
        interactionStatus.isHidden = true
        interactionStatus.isUserInteractionEnabled = false
        addSubview(interactionStatus)
        NSLayoutConstraint.activate([
            interactionStatus.centerXAnchor.constraint(equalTo: centerXAnchor),
            interactionStatus.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
            interactionStatus.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            interactionStatus.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16),
        ])
    }

    private func makeShortcutBar() -> UIView {
        let bar = UIInputView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 56),
            inputViewStyle: .keyboard
        )
        bar.autoresizingMask = [.flexibleWidth]

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        let keys = UIStackView()
        keys.translatesAutoresizingMaskIntoConstraints = false
        keys.spacing = 4
        scroll.addSubview(keys)
        bar.addSubview(scroll)
        for (title, symbol): (String, UInt32) in [
            ("Esc", 0xff1b), ("Tab", 0xff09),
        ] {
            let button = shortcutButton(title: title) { [weak self] in self?.sendKey(symbol: symbol) }
            keys.addArrangedSubview(button)
        }
        for modifier: MobileKeyboardModifier in [.command, .control, .option, .shift] {
            let button = shortcutButton(title: modifier.title, type: .custom) { [weak self] in
                guard let self, self.acceptsInput else { return }
                self.keyboardState.toggle(modifier)
                self.updateKeyboardFeedback()
            }
            modifierButtons[modifier] = button
            keys.addArrangedSubview(button)
        }
        for (title, symbol): (String, UInt32) in [
            ("←", 0xff51), ("↑", 0xff52), ("↓", 0xff54), ("→", 0xff53),
        ] {
            keys.addArrangedSubview(shortcutButton(title: title) { [weak self] in
                self?.sendKey(symbol: symbol)
            })
        }
        let done = shortcutButton(title: "") { [weak self] in self?.dismissKeyboard?() }
        done.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        done.accessibilityLabel = "Hide keyboard"
        done.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(done)
        let more = shortcutButton(title: "") {}
        more.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        more.accessibilityLabel = "More remote keys"
        more.showsMenuAsPrimaryAction = true
        let shortcuts: [(String, UInt32, Set<MobileKeyboardModifier>)] = [
            ("Copy · ⌘C", 0x63, [.command]), ("Paste · ⌘V", 0x76, [.command]),
            ("Cut · ⌘X", 0x78, [.command]), ("Undo · ⌘Z", 0x7a, [.command]),
            ("Redo · ⇧⌘Z", 0x7a, [.command, .shift]), ("Select All · ⌘A", 0x61, [.command]),
            ("Switch App · ⌘Tab", 0xff09, [.command]),
        ]
        more.menu = UIMenu(children: [
            UIMenu(title: "Shortcuts", options: .displayInline, children: shortcuts.map { title, symbol, modifiers in
                UIAction(title: title) { [weak self] _ in
                    self?.sendKey(symbol: symbol, explicitModifiers: modifiers)
                }
            }),
            UIMenu(title: "Navigation", options: .displayInline, children: [
                ("Delete ⌦", UInt32(0xffff)), ("Home", 0xff50), ("End", 0xff57),
                ("Page Up", 0xff55), ("Page Down", 0xff56),
            ].map { title, symbol in
                UIAction(title: title) { [weak self] _ in self?.sendKey(symbol: symbol) }
            }),
            UIMenu(title: "F1–F12", children: (1...12).map { number in
                UIAction(title: "F\(number)") { [weak self] _ in
                    self?.sendKey(symbol: 0xffbe + UInt32(number - 1))
                }
            }),
        ])
        more.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(more)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: more.leadingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: bar.topAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -6),
            keys.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            keys.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            keys.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            keys.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            keys.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            done.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            done.topAnchor.constraint(equalTo: scroll.topAnchor),
            done.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            more.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -4),
            more.topAnchor.constraint(equalTo: scroll.topAnchor),
            more.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
        ])
        updateKeyboardFeedback()
        return bar
    }

    private func shortcutButton(
        title: String,
        type: UIButton.ButtonType = .system,
        action: @escaping () -> Void
    ) -> UIButton {
        let button = UIButton(type: type)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .callout)
        button.backgroundColor = .tertiarySystemFill
        button.layer.cornerRadius = 6
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func updateKeyboardFeedback() {
        for (modifier, button) in modifierButtons {
            let selected = keyboardState.modifiers.contains(modifier)
            button.isSelected = selected
            button.backgroundColor = selected ? .systemBlue.withAlphaComponent(0.7) : .tertiarySystemFill
            button.setTitleColor(.systemBlue, for: .normal)
            button.setTitleColor(.white, for: .selected)
            button.setTitleColor(.white, for: [.selected, .highlighted])
            button.tintColor = selected ? .white : .systemBlue
            button.accessibilityValue = selected ? "Next key" : "Off"
            button.accessibilityTraits = selected ? [.button, .selected] : [.button]
        }
    }

    private func sendKey(symbol: UInt32, explicitModifiers: Set<MobileKeyboardModifier>? = nil) {
        guard acceptsInput else { return }
        let events = keyboardState.consume(symbol: symbol, explicitModifiers: explicitModifiers)
        updateKeyboardFeedback()
        enqueueInput { input in
            for event in events {
                await input.key(isDown: event.isDown, symbol: event.symbol)
            }
        }
    }

    private func enqueueInput(
        _ operation: @escaping @MainActor @Sendable (AppleInputController) async -> Void
    ) {
        guard acceptsInput else { return }
        let input = input
        inputQueue.enqueue {
            guard let input else { return }
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
            layouts: AppleVideoCanvasLayout.tiles(canvas: canvas, bounds: bounds, viewport: viewport),
            fullCanvasLayout: AppleVideoCanvasLayout.fullCanvas(canvas: canvas, bounds: bounds, viewport: viewport),
            canvasSize: CGSize(width: canvas.width, height: canvas.height),
            bounds: bounds
        )
    }

    private var fittedCanvasFrame: CGRect {
        AppleVideoCanvasLayout.fullCanvas(canvas: stream.canvas, bounds: bounds).container
    }

    private func followMovedPointer(_ point: MobileRemotePointerState.Point) {
        if let basePoint = AppleVideoCanvasLayout.localPoint(
            remoteX: point.x, remoteY: point.y, canvas: stream.canvas, bounds: bounds
        ), viewport.reveal(basePoint: basePoint, base: fittedCanvasFrame, bounds: bounds) {
            updateLayout()
            displayScheduler.markNeedsPresentation()
        }
        updateCursorPosition(point)
    }

    private func refreshViewport() {
        updateLayout()
        updateCursorPosition(pointerState.currentPoint(canvas: stream.canvas))
        displayScheduler.markNeedsPresentation()
        fitCanvasButton.isHidden = viewport.scale == 1
        fitCanvasButton.setTitle("\(Int((viewport.scale * 100).rounded()))% · Fit", for: .normal)
        fitCanvasButton.accessibilityValue = "\(Int((viewport.scale * 100).rounded())) percent"
    }

    @objc private func fitCanvas() {
        cancelInteractions()
        viewport.reset()
        refreshViewport()
    }

    @objc private func didPanViewport(_ recognizer: UIPanGestureRecognizer) {
        guard acceptsInput else { return }
        if recognizer.state == .began { cancelInteractions() }
        guard [.began, .changed, .ended].contains(recognizer.state) else { return }
        viewport.pan(by: recognizer.translation(in: self), base: fittedCanvasFrame, bounds: bounds)
        recognizer.setTranslation(.zero, in: self)
        refreshViewport()
    }

    private func configureViewportControls() {
        fitCanvasButton.translatesAutoresizingMaskIntoConstraints = false
        fitCanvasButton.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        fitCanvasButton.tintColor = .white
        fitCanvasButton.titleLabel?.font = .preferredFont(forTextStyle: .callout)
        fitCanvasButton.layer.cornerRadius = 8
        fitCanvasButton.isHidden = true
        fitCanvasButton.accessibilityLabel = "Fit remote screen"
        fitCanvasButton.accessibilityHint = "Reset zoom. Use three fingers to move the zoomed screen."
        fitCanvasButton.addTarget(self, action: #selector(fitCanvas), for: .touchUpInside)
        addSubview(fitCanvasButton)
        NSLayoutConstraint.activate([
            fitCanvasButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
            fitCanvasButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -12),
            fitCanvasButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            fitCanvasButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var touchedView = touch.view
        while let view = touchedView, view !== self {
            if view is UIControl { return false }
            touchedView = view.superview
        }
        return true
    }
}
