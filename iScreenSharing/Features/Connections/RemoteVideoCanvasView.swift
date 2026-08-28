import CoreVideo
import OSLog
import QuartzCore
import SwiftUI

struct RemoteVideoCanvasView: NSViewRepresentable {
    let renderer: AppleVideoRenderer
    let canvas: AppleCanvas
    let frames: AppleVideoFrameStore
    let performance: AppleVideoPerformanceMonitor
    let input: AppleInputController?
    let fileTransfer: AppleFileTransferService?
    let cursors: AppleCursorStore?
    let displayScale: AppleVideoDisplayScale
    let stretchesVideoToFillBounds: Bool
    let synchronizesPresentation: Bool
    let showsDeveloperHUD: Bool
    let sourceRect: CGRect?
    let inputMapping: AppleDisplayInputMapping?
    let inputCoordinatesAreDisplayLocal: Bool
    let inputDisplayID: UInt32?
    let onWindowKeyChange: (Bool) -> Void
    let onLiveResizeChange: (Bool, CGSize) -> Void

    func makeNSView(context: Context) -> RemoteVideoCanvasNSView {
        RemoteVideoCanvasNSView(
            renderer: renderer,
            canvas: canvas,
            frames: frames,
            input: input,
            fileTransfer: fileTransfer,
            cursors: cursors,
            displayScale: displayScale,
            stretchesVideoToFillBounds: stretchesVideoToFillBounds,
            synchronizesPresentation: synchronizesPresentation,
            showsDeveloperHUD: showsDeveloperHUD,
            sourceRect: sourceRect,
            inputMapping: inputMapping,
            inputCoordinatesAreDisplayLocal: inputCoordinatesAreDisplayLocal,
            inputDisplayID: inputDisplayID,
            onWindowKeyChange: onWindowKeyChange,
            onLiveResizeChange: onLiveResizeChange,
            performance: performance
        )
    }

    func updateNSView(_ view: RemoteVideoCanvasNSView, context: Context) {
        view.update(canvas: canvas)
        view.displayScale = displayScale
        view.stretchesVideoToFillBounds = stretchesVideoToFillBounds
        view.synchronizesPresentation = synchronizesPresentation
        view.showsDeveloperHUD = showsDeveloperHUD
        view.sourceRect = sourceRect
        view.inputMapping = inputMapping
        view.inputCoordinatesAreDisplayLocal = inputCoordinatesAreDisplayLocal
        view.inputDisplayID = inputDisplayID
        view.onWindowKeyChange = onWindowKeyChange
        view.onLiveResizeChange = onLiveResizeChange
        view.updateInput(input)
        view.updateFileTransfer(fileTransfer)
    }

    static func dismantleNSView(_ view: RemoteVideoCanvasNSView, coordinator: ()) {
        view.prepareForDismantle()
    }
}

@MainActor
private final class RemoteVideoCanvasDisplayLinkTarget: NSObject {
    weak var view: RemoteVideoCanvasNSView?

    init(view: RemoteVideoCanvasNSView) {
        self.view = view
    }

    @objc func displayLinkDidFire(_ displayLink: CADisplayLink) {
        view?.displayLinkDidFire(displayLink)
    }
}

@MainActor
final class AppleVideoRenderer {
    private var retainedLayer: AppleNV24MetalLayer?

    func displayLayer(
        synchronizesPresentation: Bool,
        showsDeveloperHUD: Bool,
        performance: AppleVideoPerformanceMonitor?
    ) -> CALayer {
        if let retainedLayer {
            retainedLayer.prepareForReuse(
                synchronizesPresentation: synchronizesPresentation,
                showsDeveloperHUD: showsDeveloperHUD,
                performance: performance
            )
            return retainedLayer
        }
        guard let context = AppleNV24MetalContext() else {
            let fallback = CALayer()
            fallback.backgroundColor = NSColor.black.cgColor
            return fallback
        }
        let layer = AppleNV24MetalLayer(
            context: context,
            synchronizesPresentation: synchronizesPresentation,
            showsDeveloperHUD: showsDeveloperHUD,
            performance: performance
        )
        retainedLayer = layer
        return layer
    }

    func snapshot() -> NSImage? {
        guard let image = retainedLayer?.snapshot() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

final class RemoteVideoCanvasNSView: NSView {
    private static let diagnosticsLogger = Logger(
        subsystem: "com.wangkai.iShareScreen",
        category: "VideoPerformance"
    )
    private struct ActiveModifier {
        let symbol: UInt32
        let keyboardType: UInt16
    }

    private struct LocalFileDrag {
        enum Outcome {
            case active
            case concluded
            case cancelled
        }

        let identifier: UUID
        let fileURL: URL
        var sessionID: UInt32?
        var latestPoint: (x: Int, y: Int)
        var outcome: Outcome
    }

    var displayScale: AppleVideoDisplayScale {
        didSet { needsLayout = true }
    }
    var stretchesVideoToFillBounds: Bool {
        didSet {
            guard stretchesVideoToFillBounds != oldValue else { return }
            needsLayout = true
            schedulePresentation()
        }
    }
    var synchronizesPresentation: Bool {
        didSet {
            guard synchronizesPresentation != oldValue else { return }
            configureDisplayLink()
            schedulePresentation()
        }
    }
    var showsDeveloperHUD: Bool {
        didSet {
            guard showsDeveloperHUD != oldValue else { return }
            (displayLayer as? AppleNV24MetalLayer)?.showsDeveloperHUD = showsDeveloperHUD
        }
    }
    var sourceRect: CGRect? {
        didSet {
            guard sourceRect != oldValue else { return }
            needsLayout = true
        }
    }
    var inputMapping: AppleDisplayInputMapping?
    var inputCoordinatesAreDisplayLocal: Bool
    var inputDisplayID: UInt32?
    var onWindowKeyChange: (Bool) -> Void
    var onLiveResizeChange: (Bool, CGSize) -> Void

    private(set) var canvas: AppleCanvas
    private let frames: AppleVideoFrameStore
    private let performance: AppleVideoPerformanceMonitor?
    private var input: AppleInputController?
    private var fileTransfer: AppleFileTransferService?
    private let cursors: AppleCursorStore?
    private let displayLayer: CALayer
    private var observer: UUID?
    private var cursorObserver: UUID?
    private var remoteCursor = NSCursor.arrow
    private var decodedTileHeights: [CGFloat?]
    private var decodedFullCanvasSize: CGSize?
    private var trackingArea: NSTrackingArea?
    private var windowDidBecomeKeyObserver: NSObjectProtocol?
    private var windowDidResignKeyObserver: NSObjectProtocol?
    private var windowDidChangeScreenObserver: NSObjectProtocol?
    private var reportedWindowIsKey = false
    private var buttonMask: UInt8 = 0
    private var lastRemotePoint: (x: Int, y: Int)?
    private var activeModifiers = [UInt16: ActiveModifier]()
    private var inputTask: Task<Void, Never>?
    private var fileDragTask: Task<Void, Never>?
    private var localFileDrag: LocalFileDrag?
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: RemoteVideoCanvasDisplayLinkTarget?
    private var displayScheduler = AppleVideoDisplayScheduler()

    var usesSynchronizedDisplayLink: Bool { displayLink != nil }

    init(
        renderer: AppleVideoRenderer? = nil,
        canvas: AppleCanvas,
        frames: AppleVideoFrameStore,
        input: AppleInputController?,
        fileTransfer: AppleFileTransferService? = nil,
        cursors: AppleCursorStore?,
        displayScale: AppleVideoDisplayScale,
        stretchesVideoToFillBounds: Bool = false,
        synchronizesPresentation: Bool,
        showsDeveloperHUD: Bool = false,
        sourceRect: CGRect?,
        inputMapping: AppleDisplayInputMapping?,
        inputCoordinatesAreDisplayLocal: Bool,
        inputDisplayID: UInt32?,
        onWindowKeyChange: @escaping (Bool) -> Void = { _ in },
        onLiveResizeChange: @escaping (Bool, CGSize) -> Void = { _, _ in },
        performance: AppleVideoPerformanceMonitor? = nil
    ) {
        self.canvas = canvas
        self.frames = frames
        self.performance = performance
        self.input = input
        self.fileTransfer = fileTransfer
        self.cursors = cursors
        self.displayScale = displayScale
        self.stretchesVideoToFillBounds = stretchesVideoToFillBounds
        self.synchronizesPresentation = synchronizesPresentation
        self.showsDeveloperHUD = showsDeveloperHUD
        self.sourceRect = sourceRect
        self.inputMapping = inputMapping
        self.inputCoordinatesAreDisplayLocal = inputCoordinatesAreDisplayLocal
        self.inputDisplayID = inputDisplayID
        self.onWindowKeyChange = onWindowKeyChange
        self.onLiveResizeChange = onLiveResizeChange
        decodedTileHeights = Array(repeating: nil, count: canvas.tileCount)
        displayLayer = (renderer ?? AppleVideoRenderer()).displayLayer(
            synchronizesPresentation: synchronizesPresentation,
            showsDeveloperHUD: showsDeveloperHUD,
            performance: performance
        )
        super.init(frame: .zero)

        registerForDraggedTypes([.fileURL])

        var displayLayerActions = displayLayer.actions ?? [:]
        displayLayerActions["bounds"] = NSNull()
        displayLayerActions["position"] = NSNull()
        displayLayer.actions = displayLayerActions

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
        observer = frames.addObserver { [weak self] frames in
            self?.enqueueForPresentation(frames)
        }
        cursorObserver = cursors?.addObserver { [weak self] image in
            self?.applyCursor(image)
        }
        applyCursor(cursors?.currentImage())
        enqueueForPresentation(currentFrames())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        displayLink?.invalidate()
        inputTask?.cancel()
        fileDragTask?.cancel()
        reportWindowIsKey(false)
        removeWindowObservers()
        if let observer { frames.removeObserver(observer) }
        if let cursorObserver { cursors?.removeObserver(cursorObserver) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeWindowObservers()
        configureDisplayLink()
        reportWindowIsKey(window?.isKeyWindow == true)
        guard let window else { return }
        windowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reportWindowIsKey(true)
                self?.selectInputDisplay()
            }
        }
        windowDidResignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportWindowIsKey(false) }
        }
        windowDidChangeScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDisplayEnvironment(resetCadence: true) }
        }
        reportWindowIsKey(window.isKeyWindow)
        if window.isKeyWindow { selectInputDisplay() }
        refreshDisplayEnvironment(resetCadence: true)
        enqueueForPresentation(currentFrames())
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshDisplayEnvironment(resetCadence: false)
    }

    override func layout() {
        super.layout()
        updateDisplayLayerGeometry()
        schedulePresentation()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        onLiveResizeChange(true, bounds.size)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onLiveResizeChange(false, bounds.size)
    }

    private func updateDisplayLayerGeometry() {
        let fallbackHeight = ceil(CGFloat(canvas.height) / CGFloat(canvas.tileCount))
        let slotHeights = decodedTileHeights.map { $0 ?? fallbackHeight }
        let layouts = AppleVideoCanvasLayout.tiles(
            canvas: canvas,
            bounds: bounds,
            slotHeights: slotHeights,
            fixedScale: displayScale.fixedScale,
            sourceRect: sourceRect,
            stretchesToFillBounds: stretchesVideoToFillBounds
        )
        let fullCanvasLayout = AppleVideoCanvasLayout.fullCanvas(
            canvas: canvas,
            bounds: bounds,
            storageSize: decodedFullCanvasSize,
            fixedScale: displayScale.fixedScale,
            sourceRect: sourceRect,
            stretchesToFillBounds: stretchesVideoToFillBounds
        )
        displayLayer.frame = bounds
        (displayLayer as? AppleNV24MetalLayer)?.update(
            layouts: layouts,
            fullCanvasLayout: fullCanvasLayout,
            canvasSize: CGSize(width: canvas.width, height: canvas.height),
            bounds: bounds
        )
    }

    func update(canvas: AppleCanvas) {
        guard canvas != self.canvas else { return }
        self.canvas = canvas
        decodedTileHeights = Array(repeating: nil, count: canvas.tileCount)
        decodedFullCanvasSize = nil
        displayScheduler.reset()
        needsLayout = true
        schedulePresentation()
    }

    func updateInput(_ input: AppleInputController?) {
        self.input = input
    }

    func updateFileTransfer(_ fileTransfer: AppleFileTransferService?) {
        self.fileTransfer = fileTransfer
    }

    fileprivate func prepareForDismantle() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
        displayScheduler.reset()
        cancelLocalFileDrag()
        unregisterDraggedTypes()
        reportWindowIsKey(false)
        removeWindowObservers()
        if let observer {
            frames.removeObserver(observer)
            self.observer = nil
        }
        if let cursorObserver {
            cursors?.removeObserver(cursorObserver)
            self.cursorObserver = nil
        }
        (displayLayer as? AppleNV24MetalLayer)?.prepareForInactivity()
        displayLayer.removeFromSuperlayer()
    }

    override var acceptsFirstResponder: Bool { true }

    // The activation click is also remote input. If AppKit consumes it only to
    // activate the window, remote control incorrectly requires a second click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: remoteCursor)
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .enabledDuringMouseDrag],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) { sendPointer(event) }
    override func mouseDragged(with event: NSEvent) { sendPointer(event) }
    override func rightMouseDragged(with event: NSEvent) { sendPointer(event) }
    override func otherMouseDragged(with event: NSEvent) { sendPointer(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        buttonMask |= AppleInputController.leftButton
        sendPointer(event)
    }

    override func mouseUp(with event: NSEvent) {
        buttonMask &= ~AppleInputController.leftButton
        sendPointer(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        buttonMask |= AppleInputController.rightButton
        sendPointer(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        buttonMask &= ~AppleInputController.rightButton
        sendPointer(event)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        window?.makeFirstResponder(self)
        buttonMask |= AppleInputController.middleButton
        sendPointer(event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        buttonMask &= ~AppleInputController.middleButton
        sendPointer(event)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard input != nil, let fileTransfer, !fileTransfer.history.preventsNewDrop,
              localFileDrag == nil,
              let fileURL = draggedRegularFileURL(from: sender),
              let point = remotePoint(forDraggingLocation: sender.draggingLocation) else {
            return []
        }
        let identifier = UUID()
        localFileDrag = LocalFileDrag(
            identifier: identifier,
            fileURL: fileURL,
            sessionID: nil,
            latestPoint: point,
            outcome: .active
        )
        fileDragTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let sessionID = try await fileTransfer.beginDrop(fileURL: fileURL)
                guard var drag = localFileDrag, drag.identifier == identifier else {
                    await fileTransfer.cancelDrop(sessionID: sessionID)
                    return
                }
                drag.sessionID = sessionID
                localFileDrag = drag
                switch drag.outcome {
                case .active:
                    sendDraggedPointer(buttons: AppleInputController.leftButton, point: drag.latestPoint)
                case .concluded:
                    sendDraggedPointer(buttons: 0, point: drag.latestPoint)
                    localFileDrag = nil
                case .cancelled:
                    await fileTransfer.cancelDrop(sessionID: sessionID)
                    sendDraggedPointer(buttons: 0, point: drag.latestPoint)
                    localFileDrag = nil
                }
            } catch is CancellationError {
                if localFileDrag?.identifier == identifier { localFileDrag = nil }
            } catch {
                if localFileDrag?.identifier == identifier { localFileDrag = nil }
                NSSound.beep()
            }
        }
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard var drag = localFileDrag,
              let point = remotePoint(forDraggingLocation: sender.draggingLocation) else {
            return []
        }
        drag.latestPoint = point
        localFileDrag = drag
        if drag.sessionID != nil {
            sendDraggedPointer(buttons: AppleInputController.leftButton, point: point)
        }
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        guard var drag = localFileDrag else { return }
        drag.outcome = .cancelled
        localFileDrag = drag
        if let sessionID = drag.sessionID, let fileTransfer {
            Task { await fileTransfer.cancelDrop(sessionID: sessionID) }
            sendDraggedPointer(buttons: 0, point: drag.latestPoint)
            localFileDrag = nil
        }
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard var drag = localFileDrag else { return false }
        if let point = remotePoint(forDraggingLocation: sender.draggingLocation) {
            drag.latestPoint = point
        }
        drag.outcome = .concluded
        localFileDrag = drag
        if drag.sessionID != nil {
            sendDraggedPointer(buttons: 0, point: drag.latestPoint)
            localFileDrag = nil
        }
        return true
    }

    override func scrollWheel(with event: NSEvent) {
        guard let input, let point = remotePoint(for: event) ?? lastRemotePoint else { return }
        if let scrollEvent = Self.scrollWheelEvent(from: event) {
            enqueueInput {
                await input.scroll(
                    event: scrollEvent,
                    x: point.x,
                    y: point.y,
                    displayID: self.inputDisplayID
                )
            }
        } else {
            enqueueInput {
                await input.scroll(
                    verticalTicks: Self.direction(of: event.deltaY),
                    horizontalTicks: Self.direction(of: event.deltaX),
                    x: point.x,
                    y: point.y,
                    displayID: self.inputDisplayID
                )
            }
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard let input, let modifier = AppleKeySymbol.modifier(for: event.keyCode) else { return }
        let keyboardType = Self.keyboardType(for: event)
        let symbol: UInt32
        let isDown: Bool
        if let active = activeModifiers.removeValue(forKey: event.keyCode) {
            symbol = active.symbol
            isDown = false
        } else if event.modifierFlags.contains(modifier.flag) {
            symbol = modifier.symbol
            activeModifiers[event.keyCode] = ActiveModifier(
                symbol: symbol,
                keyboardType: keyboardType
            )
            isDown = true
        } else {
            return
        }
        enqueueInput {
            await input.key(
                isDown: isDown,
                symbol: symbol,
                keyCode: event.keyCode,
                keyboardType: keyboardType
            )
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard input != nil, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let input else { return }
        let keyboardType = Self.keyboardType(for: event)
        if let symbol = AppleKeySymbol.special[event.keyCode] {
            enqueueInput {
                await input.key(
                    isDown: true,
                    symbol: symbol,
                    keyCode: event.keyCode,
                    keyboardType: keyboardType
                )
            }
            return
        }
        let hasCommandModifier = !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        let characters = hasCommandModifier ? event.charactersIgnoringModifiers : event.characters
        guard let symbols = characters?.unicodeScalars.map(\.value), !symbols.isEmpty else { return }
        enqueueInput {
            for symbol in symbols {
                await input.key(
                    isDown: true,
                    symbol: symbol,
                    keyCode: event.keyCode,
                    keyboardType: keyboardType
                )
                if !hasCommandModifier {
                    await input.key(
                        isDown: false,
                        symbol: symbol,
                        keyCode: event.keyCode,
                        keyboardType: keyboardType
                    )
                }
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let input else { return }
        let keyboardType = Self.keyboardType(for: event)
        if let symbol = AppleKeySymbol.special[event.keyCode] {
            enqueueInput {
                await input.key(
                    isDown: false,
                    symbol: symbol,
                    keyCode: event.keyCode,
                    keyboardType: keyboardType
                )
            }
            return
        }
        guard !event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let symbols = event.charactersIgnoringModifiers?.unicodeScalars.map(\.value) else { return }
        enqueueInput {
            for symbol in symbols {
                await input.key(
                    isDown: false,
                    symbol: symbol,
                    keyCode: event.keyCode,
                    keyboardType: keyboardType
                )
            }
        }
    }

    override func resignFirstResponder() -> Bool {
        if let input {
            let modifiers = activeModifiers
            activeModifiers.removeAll()
            let shouldReleasePointer = buttonMask != 0
            buttonMask = 0
            let point = lastRemotePoint
            enqueueInput {
                for (keyCode, modifier) in modifiers {
                    await input.key(
                        isDown: false,
                        symbol: modifier.symbol,
                        keyCode: keyCode,
                        keyboardType: modifier.keyboardType
                    )
                }
                if shouldReleasePointer, let point {
                    await input.pointer(buttons: 0, x: point.x, y: point.y, displayID: self.inputDisplayID)
                }
            }
        }
        return super.resignFirstResponder()
    }

    private func sendPointer(_ event: NSEvent) {
        guard let input, let point = remotePoint(for: event) else { return }
        lastRemotePoint = point
        let buttons = buttonMask
        let clickCount = event.clickCount
        enqueueInput {
            await input.pointer(
                buttons: buttons,
                x: point.x,
                y: point.y,
                displayID: self.inputDisplayID,
                clickCount: clickCount
            )
        }
    }

    private func sendDraggedPointer(buttons: UInt8, point: (x: Int, y: Int)) {
        guard let input else { return }
        lastRemotePoint = point
        let displayID = inputDisplayID
        enqueueInput {
            await input.fileDragPointer(
                buttons: buttons,
                x: point.x,
                y: point.y,
                displayID: displayID
            )
        }
    }

    private func draggedRegularFileURL(from sender: any NSDraggingInfo) -> URL? {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], urls.count == 1 else { return nil }
        let values = try? urls[0].resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true ? urls[0] : nil
    }

    private func remotePoint(forDraggingLocation location: NSPoint) -> (x: Int, y: Int)? {
        let localLocation = convert(location, from: nil)
        guard let canvasPoint = AppleVideoCanvasLayout.remotePoint(
            location: localLocation,
            canvas: canvas,
            bounds: bounds,
            fixedScale: displayScale.fixedScale,
            sourceRect: sourceRect,
            stretchesToFillBounds: stretchesVideoToFillBounds
        ) else { return nil }
        return Self.mappedInputPoint(
            canvasPoint,
            mapping: inputMapping,
            requiresDisplayMapping: inputCoordinatesAreDisplayLocal
        )
    }

    private func cancelLocalFileDrag() {
        fileDragTask?.cancel()
        fileDragTask = nil
        guard let drag = localFileDrag else { return }
        localFileDrag = nil
        if let sessionID = drag.sessionID, let fileTransfer {
            Task { await fileTransfer.cancelDrop(sessionID: sessionID) }
            sendDraggedPointer(buttons: 0, point: drag.latestPoint)
        }
    }

    private func enqueueInput(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        let previous = inputTask
        inputTask = Task { @MainActor in
            _ = await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    private func remotePoint(for event: NSEvent) -> (x: Int, y: Int)? {
        let location = convert(event.locationInWindow, from: nil)
        guard let canvasPoint = AppleVideoCanvasLayout.remotePoint(
            location: location,
            canvas: canvas,
            bounds: bounds,
            fixedScale: displayScale.fixedScale,
            sourceRect: sourceRect,
            stretchesToFillBounds: stretchesVideoToFillBounds
        ) else { return nil }
        return Self.mappedInputPoint(
            canvasPoint,
            mapping: inputMapping,
            requiresDisplayMapping: inputCoordinatesAreDisplayLocal
        )
    }

    static func mappedInputPoint(
        _ canvasPoint: (x: Int, y: Int),
        mapping: AppleDisplayInputMapping?,
        requiresDisplayMapping: Bool
    ) -> (x: Int, y: Int)? {
        if requiresDisplayMapping {
            guard let mapping else { return nil }
            return mapping.point(
                from: CGPoint(x: canvasPoint.x, y: canvasPoint.y),
                isDisplayLocal: true
            )
        }
        return mapping?.point(
            from: CGPoint(x: canvasPoint.x, y: canvasPoint.y),
            isDisplayLocal: false
        ) ?? canvasPoint
    }

    private func selectInputDisplay() {
        guard let input else { return }
        let displayID = inputDisplayID
        enqueueInput { await input.selectDisplay(displayID) }
    }

    private func enqueueForPresentation(_ frames: AppleVideoFrameStore.FrameBatch) {
        guard !frames.isEmpty else { return }
        let mainDeliveredAt = CACurrentMediaTime()
        for frame in frames.values {
            performance?.recordFrameDelivery(
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
        if synchronizesPresentation {
            if let update = displayScheduler.enqueue(frames) {
                applyAndPresent(update)
            }
        } else {
            performance?.recordSchedulerSelection(
                frameKeys: frames.values.map(\.sequence),
                selectedAt: mainDeliveredAt
            )
            apply(frames)
            schedulePresentation()
        }
    }

    private func apply(_ frames: AppleVideoFrameStore.FrameBatch) {
        precondition(Thread.isMainThread)
        guard !frames.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (tileIndex, frame) in frames.sorted(by: { $0.key < $1.key }) {
            display(frame, at: tileIndex)
        }
    }

    private func display(_ frame: AppleVideoFrameStore.Frame, at tileIndex: Int) {
        if tileIndex == AppleVideoFrameStore.fullCanvasIndex {
            let pixelBuffer = frame.pixelBuffer
            let size = CGSize(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
            if decodedFullCanvasSize != size {
                decodedFullCanvasSize = size
                updateDisplayLayerGeometry()
            }
            (displayLayer as? AppleNV24MetalLayer)?.update(frame, at: tileIndex)
            return
        }
        guard decodedTileHeights.indices.contains(tileIndex) else { return }
        let switchedFromFullCanvas = decodedFullCanvasSize != nil
        decodedFullCanvasSize = nil
        let pixelBuffer = frame.pixelBuffer
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        if decodedTileHeights[tileIndex] != height {
            decodedTileHeights[tileIndex] = height
            needsLayout = true
        }
        if switchedFromFullCanvas {
            updateDisplayLayerGeometry()
        }

        (displayLayer as? AppleNV24MetalLayer)?.update(frame, at: tileIndex)
    }

    fileprivate func displayLinkDidFire(_ displayLink: CADisplayLink) {
        let callbackTime = CACurrentMediaTime()
        performance?.recordDisplayLink(
            lead: displayLink.targetTimestamp - callbackTime,
            period: displayLink.targetTimestamp - displayLink.timestamp
        )
        let period = displayLink.targetTimestamp - displayLink.timestamp
        let update = displayScheduler.displayLinkDidFire(
            targetTimestamp: displayLink.targetTimestamp,
            period: period
        )
        applyAndPresent(update)
    }

    private func applyAndPresent(_ update: AppleVideoDisplayScheduler.DisplayUpdate) {
        if !update.frames.isEmpty {
            performance?.recordSchedulerSelection(
                frameKeys: update.frames.values.map(\.sequence),
                selectedAt: CACurrentMediaTime()
            )
            apply(update.frames)
        }
        guard update.requiresPresentation else { return }
        let presented = (displayLayer as? AppleNV24MetalLayer)?.present(
            targetTimestamp: update.targetTimestamp,
            displayPeriod: update.displayPeriod,
            isDisplayLinkTriggered: update.trigger == .displayLinkTick
        ) ?? true
        if !presented { displayScheduler.presentationDidFail() }
    }

    private func configureDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
        displayScheduler.invalidateDisplayTarget()
        guard let metalLayer = displayLayer as? AppleNV24MetalLayer else { return }

        metalLayer.synchronizesPresentation = synchronizesPresentation
        guard synchronizesPresentation else {
            let pendingFrames = displayScheduler.takeLatestFrames()
            if !pendingFrames.isEmpty { apply(pendingFrames) }
            return
        }
        guard let window else { return }

        let target = RemoteVideoCanvasDisplayLinkTarget(view: self)
        let displayLink = window.displayLink(
            target: target,
            selector: #selector(RemoteVideoCanvasDisplayLinkTarget.displayLinkDidFire(_:))
        )
        displayLink.add(to: .main, forMode: .common)
        displayLinkTarget = target
        self.displayLink = displayLink
        updateDisplayLinkFrameRate()
    }

    private func refreshDisplayEnvironment(resetCadence: Bool) {
        guard let window else { return }
        updateDisplayLinkFrameRate()
        displayLayer.contentsScale = window.backingScaleFactor
        if resetCadence { performance?.resetDisplayCadence() }
        needsLayout = true
        schedulePresentation()
    }

    private func updateDisplayLinkFrameRate() {
        guard let displayLink else { return }
        let frameRate = Float(max(
            1,
            window?.screen?.maximumFramesPerSecond
                ?? NSScreen.main?.maximumFramesPerSecond
                ?? 60
        ))
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: frameRate,
            maximum: frameRate,
            preferred: frameRate
        )
    }

    private func removeWindowObservers() {
        if let windowDidBecomeKeyObserver {
            NotificationCenter.default.removeObserver(windowDidBecomeKeyObserver)
            self.windowDidBecomeKeyObserver = nil
        }
        if let windowDidResignKeyObserver {
            NotificationCenter.default.removeObserver(windowDidResignKeyObserver)
            self.windowDidResignKeyObserver = nil
        }
        if let windowDidChangeScreenObserver {
            NotificationCenter.default.removeObserver(windowDidChangeScreenObserver)
            self.windowDidChangeScreenObserver = nil
        }
    }

    private func reportWindowIsKey(_ isKey: Bool) {
        guard reportedWindowIsKey != isKey else { return }
        reportedWindowIsKey = isKey
        onWindowKeyChange(isKey)
    }

    private func schedulePresentation() {
        if synchronizesPresentation {
            displayScheduler.markNeedsPresentation()
        } else {
            _ = (displayLayer as? AppleNV24MetalLayer)?.present()
        }
    }

    private func currentFrames() -> AppleVideoFrameStore.FrameBatch {
        ([AppleVideoFrameStore.fullCanvasIndex] + Array(0..<canvas.tileCount)).reduce(into: [:]) {
            result, tileIndex in
            result[tileIndex] = frames.storedFrame(at: tileIndex)
        }
    }

    private func applyCursor(_ image: AppleCursorImage?) {
        precondition(Thread.isMainThread)
        remoteCursor = image.flatMap(Self.cursor(from:)) ?? .arrow
        window?.invalidateCursorRects(for: self)
    }

    private static func cursor(from image: AppleCursorImage) -> NSCursor? {
        let (pixelCount, pixelOverflow) = image.width.multipliedReportingOverflow(by: image.height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard image.width > 0, image.height > 0, !pixelOverflow, !byteOverflow,
              image.rgba.count == byteCount,
              let representation = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: image.width,
                  pixelsHigh: image.height,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: image.width * 4,
                  bitsPerPixel: 32
              ), let bitmap = representation.bitmapData else { return nil }
        image.rgba.copyBytes(to: bitmap, count: image.rgba.count)
        let cursorImage = NSImage(size: NSSize(width: image.width, height: image.height))
        cursorImage.addRepresentation(representation)
        return NSCursor(
            image: cursorImage,
            hotSpot: NSPoint(x: image.hotspotX, y: image.hotspotY)
        )
    }

    private static func keyboardType(for event: NSEvent) -> UInt16 {
        guard let value = event.cgEvent?.getIntegerValueField(.keyboardEventKeyboardType) else {
            return 0
        }
        return UInt16(clamping: value)
    }

    private static func scrollWheelEvent(from event: NSEvent) -> AppleScrollWheelEvent? {
        guard let cgEvent = event.cgEvent else { return nil }
        return AppleScrollWheelEvent(
            deltaX: Int16(clamping: cgEvent.getIntegerValueField(.scrollWheelEventDeltaAxis2)),
            deltaY: Int16(clamping: cgEvent.getIntegerValueField(.scrollWheelEventDeltaAxis1)),
            deltaZ: Int16(clamping: cgEvent.getIntegerValueField(.scrollWheelEventDeltaAxis3)),
            fixedDeltaX: Int32(clamping: cgEvent.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2)),
            fixedDeltaY: Int32(clamping: cgEvent.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1)),
            fixedDeltaZ: Int32(clamping: cgEvent.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis3)),
            pointDeltaX: Int32(clamping: cgEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)),
            pointDeltaY: Int32(clamping: cgEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)),
            pointDeltaZ: Int32(clamping: cgEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis3)),
            scrollPhase: UInt32(truncatingIfNeeded: cgEvent.getIntegerValueField(.scrollWheelEventScrollPhase)),
            momentumPhase: UInt32(truncatingIfNeeded: cgEvent.getIntegerValueField(.scrollWheelEventMomentumPhase)),
            scrollCount: UInt32(truncatingIfNeeded: cgEvent.getIntegerValueField(.scrollWheelEventScrollCount)),
            flags: UInt32(truncatingIfNeeded: cgEvent.flags.rawValue)
        )
    }

    private static func direction(of delta: CGFloat) -> Int {
        delta == 0 ? 0 : delta > 0 ? 1 : -1
    }

}

enum AppleVideoCanvasLayout {
    struct Tile: Equatable {
        let container: CGRect
        let content: CGRect
    }

    static func fullCanvas(
        canvas: AppleCanvas,
        bounds: CGRect,
        storageSize: CGSize? = nil,
        fixedScale: CGFloat?,
        sourceRect: CGRect? = nil,
        stretchesToFillBounds: Bool = false
    ) -> Tile {
        guard canvas.width > 0, canvas.height > 0 else {
            return Tile(container: .zero, content: .zero)
        }
        let canvasBounds = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        let source = sourceRect.map { $0.intersection(canvasBounds) } ?? canvasBounds
        guard !source.isNull, !source.isEmpty else {
            return Tile(container: .zero, content: .zero)
        }
        let scaleFactors = scales(
            sourceSize: source.size,
            bounds: bounds,
            fixedScale: fixedScale,
            stretchesToFillBounds: stretchesToFillBounds
        )
        let outputSize = CGSize(
            width: source.width * scaleFactors.width,
            height: source.height * scaleFactors.height
        )
        let container = CGRect(
            x: bounds.midX - outputSize.width / 2,
            y: bounds.midY - outputSize.height / 2,
            width: outputSize.width,
            height: outputSize.height
        )
        let storage = storageSize ?? canvasBounds.size
        let content = CGRect(
            x: -source.minX * scaleFactors.width,
            y: (source.maxY - storage.height) * scaleFactors.height,
            width: storage.width * scaleFactors.width,
            height: storage.height * scaleFactors.height
        )
        return Tile(container: container, content: content)
    }

    static func tiles(
        canvas: AppleCanvas,
        bounds: CGRect,
        slotHeight: CGFloat,
        fixedScale: CGFloat?,
        sourceRect: CGRect? = nil,
        stretchesToFillBounds: Bool = false
    ) -> [Tile] {
        guard canvas.tileCount > 0 else { return [] }
        return tiles(
            canvas: canvas,
            bounds: bounds,
            slotHeights: Array(repeating: slotHeight, count: canvas.tileCount),
            fixedScale: fixedScale,
            sourceRect: sourceRect,
            stretchesToFillBounds: stretchesToFillBounds
        )
    }

    static func tiles(
        canvas: AppleCanvas,
        bounds: CGRect,
        slotHeights: [CGFloat],
        fixedScale: CGFloat?,
        sourceRect: CGRect? = nil,
        stretchesToFillBounds: Bool = false
    ) -> [Tile] {
        guard canvas.tileCount > 0, canvas.width > 0, canvas.height > 0,
              slotHeights.count == canvas.tileCount,
              slotHeights.allSatisfy({ $0 > 0 }) else {
            return []
        }
        let canvasBounds = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        let source = sourceRect.map { $0.intersection(canvasBounds) } ?? canvasBounds
        guard !source.isNull, !source.isEmpty else {
            return Array(repeating: Tile(container: .zero, content: .zero), count: canvas.tileCount)
        }
        let scaleFactors = scales(
            sourceSize: source.size,
            bounds: bounds,
            fixedScale: fixedScale,
            stretchesToFillBounds: stretchesToFillBounds
        )
        let outputSize = CGSize(
            width: source.width * scaleFactors.width,
            height: source.height * scaleFactors.height
        )
        let outputRect = CGRect(
            x: bounds.midX - outputSize.width / 2,
            y: bounds.midY - outputSize.height / 2,
            width: outputSize.width,
            height: outputSize.height
        )
        return (0..<canvas.tileCount).map { tileIndex in
            let slotHeight = slotHeights[tileIndex]
            let logicalStart = slotHeights[..<tileIndex].reduce(0, +)
            let validHeight = min(
                slotHeight,
                max(0, canvasBounds.height - logicalStart)
            )
            guard validHeight > 0 else { return Tile(container: .zero, content: .zero) }
            let tileRect = CGRect(
                x: 0,
                y: logicalStart,
                width: canvasBounds.width,
                height: validHeight
            )
            let visibleRect = tileRect.intersection(source)
            guard !visibleRect.isNull, !visibleRect.isEmpty else {
                return Tile(container: .zero, content: .zero)
            }
            let container = CGRect(
                x: outputRect.minX + (visibleRect.minX - source.minX) * scaleFactors.width,
                y: outputRect.maxY - (visibleRect.maxY - source.minY) * scaleFactors.height,
                width: visibleRect.width * scaleFactors.width,
                height: visibleRect.height * scaleFactors.height
            )
            let content = CGRect(
                x: (tileRect.minX - visibleRect.minX) * scaleFactors.width,
                y: (visibleRect.maxY - tileRect.minY - slotHeight) * scaleFactors.height,
                width: tileRect.width * scaleFactors.width,
                height: slotHeight * scaleFactors.height
            )
            return Tile(container: container, content: content)
        }
    }

    static func remotePoint(
        location: CGPoint,
        canvas: AppleCanvas,
        bounds: CGRect,
        fixedScale: CGFloat?,
        sourceRect: CGRect? = nil,
        stretchesToFillBounds: Bool = false
    ) -> (x: Int, y: Int)? {
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        let canvasBounds = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        let source = sourceRect.map { $0.intersection(canvasBounds) } ?? canvasBounds
        guard !source.isNull, !source.isEmpty else { return nil }
        let scaleFactors = scales(
            sourceSize: source.size,
            bounds: bounds,
            fixedScale: fixedScale,
            stretchesToFillBounds: stretchesToFillBounds
        )
        guard scaleFactors.width > 0, scaleFactors.height > 0 else { return nil }
        let size = CGSize(
            width: source.width * scaleFactors.width,
            height: source.height * scaleFactors.height
        )
        let rect = CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        guard rect.contains(location) else { return nil }
        let sourceX = Int(source.minX + (location.x - rect.minX) / scaleFactors.width)
        let sourceY = Int(source.minY + (rect.maxY - location.y) / scaleFactors.height)
        return (
            min(Int(source.maxX) - 1, max(Int(source.minX), sourceX)),
            min(Int(source.maxY) - 1, max(Int(source.minY), sourceY))
        )
    }

    private static func scales(
        sourceSize: CGSize,
        bounds: CGRect,
        fixedScale: CGFloat?,
        stretchesToFillBounds: Bool
    ) -> CGSize {
        if let fixedScale {
            return CGSize(width: fixedScale, height: fixedScale)
        }
        if stretchesToFillBounds {
            return CGSize(
                width: bounds.width / sourceSize.width,
                height: bounds.height / sourceSize.height
            )
        }
        let scale = min(
            bounds.width / sourceSize.width,
            bounds.height / sourceSize.height
        )
        return CGSize(width: scale, height: scale)
    }
}

private enum AppleKeySymbol {
    static let special: [UInt16: UInt32] = [
        53: 0xff1b, 48: 0xff09, 51: 0xff08, 36: 0xff0d, 117: 0xffff,
        114: 0xff63, 115: 0xff50, 119: 0xff57, 116: 0xff55, 121: 0xff56,
        123: 0xff51, 126: 0xff52, 124: 0xff53, 125: 0xff54,
        122: 0xffbe, 120: 0xffbf, 99: 0xffc0, 118: 0xffc1,
        96: 0xffc2, 97: 0xffc3, 98: 0xffc4, 100: 0xffc5,
        101: 0xffc6, 109: 0xffc7, 103: 0xffc8, 111: 0xffc9,
    ]

    static func modifier(for keyCode: UInt16) -> (flag: NSEvent.ModifierFlags, symbol: UInt32)? {
        switch keyCode {
        case 56: (.shift, 0xffe1)
        case 60: (.shift, 0xffe2)
        case 59: (.control, 0xffe3)
        case 62: (.control, 0xffe4)
        case 58: (.option, 0xffe9)
        case 61: (.option, 0xffea)
        case 55: (.command, 0xffeb)
        case 54: (.command, 0xffec)
        case 57: (.capsLock, 0xffe5)
        default: nil
        }
    }
}
