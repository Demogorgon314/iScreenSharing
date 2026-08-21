import CoreVideo
import SwiftUI

struct RemoteVideoCanvasView: NSViewRepresentable {
    let canvas: AppleCanvas
    let frames: AppleVideoFrameStore
    let input: AppleInputController?
    let cursors: AppleCursorStore?
    let displayScale: AppleVideoDisplayScale

    func makeNSView(context: Context) -> RemoteVideoCanvasNSView {
        RemoteVideoCanvasNSView(
            canvas: canvas,
            frames: frames,
            input: input,
            cursors: cursors,
            displayScale: displayScale
        )
    }

    func updateNSView(_ view: RemoteVideoCanvasNSView, context: Context) {
        view.displayScale = displayScale
    }
}

final class RemoteVideoCanvasNSView: NSView {
    var displayScale: AppleVideoDisplayScale {
        didSet { needsLayout = true }
    }

    private let canvas: AppleCanvas
    private let frames: AppleVideoFrameStore
    private let input: AppleInputController?
    private let cursors: AppleCursorStore?
    private let tileContainers: [CALayer]
    private let displayLayers: [CALayer]
    private var observer: UUID?
    private var cursorObserver: UUID?
    private var remoteCursor = NSCursor.arrow
    private var decodedTileHeight: CGFloat?
    private var trackingArea: NSTrackingArea?
    private var buttonMask: UInt8 = 0
    private var lastRemotePoint: (x: Int, y: Int)?
    private var scrollRemainder: CGFloat = 0
    private var activeModifiers = [UInt16: UInt32]()
    private var inputTask: Task<Void, Never>?

    init(
        canvas: AppleCanvas,
        frames: AppleVideoFrameStore,
        input: AppleInputController?,
        cursors: AppleCursorStore?,
        displayScale: AppleVideoDisplayScale
    ) {
        self.canvas = canvas
        self.frames = frames
        self.input = input
        self.cursors = cursors
        self.displayScale = displayScale
        let metalContext = AppleNV24MetalContext()
        tileContainers = (0..<canvas.tileCount).map { _ in CALayer() }
        displayLayers = (0..<canvas.tileCount).map { _ in
            if let metalContext { return AppleNV24MetalLayer(context: metalContext) }
            let fallback = CALayer()
            fallback.backgroundColor = NSColor.black.cgColor
            return fallback
        }
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        for (container, displayLayer) in zip(tileContainers, displayLayers) {
            container.masksToBounds = true
            container.addSublayer(displayLayer)
            layer?.addSublayer(container)
        }
        observer = frames.addObserver { [weak self] tileIndex, frame in
            self?.display(frame, at: tileIndex)
        }
        cursorObserver = cursors?.addObserver { [weak self] image in
            self?.applyCursor(image)
        }
        applyCursor(cursors?.currentImage())
        for tileIndex in displayLayers.indices {
            if let frame = frames.frame(at: tileIndex) { display(frame, at: tileIndex) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        inputTask?.cancel()
        if let observer { frames.removeObserver(observer) }
        if let cursorObserver { cursors?.removeObserver(cursorObserver) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        let scale = window?.backingScaleFactor ?? 1
        displayLayers.forEach { $0.contentsScale = scale }
        for tileIndex in displayLayers.indices {
            if let frame = frames.frame(at: tileIndex) {
                display(frame, at: tileIndex)
            }
        }
    }

    override func layout() {
        super.layout()
        let slotHeight = decodedTileHeight ?? ceil(CGFloat(canvas.height) / CGFloat(canvas.tileCount))
        let layouts = AppleVideoCanvasLayout.tiles(
            canvas: canvas,
            bounds: bounds,
            slotHeight: slotHeight,
            fixedScale: displayScale.fixedScale
        )
        for (index, layout) in layouts.enumerated() {
            tileContainers[index].frame = backingAlignedRect(
                layout.container,
                options: [.alignMinXOutward, .alignMaxXOutward, .alignMinYOutward, .alignMaxYOutward]
            )
            displayLayers[index].frame = backingAlignedRect(
                layout.content,
                options: [.alignMinXOutward, .alignMaxXOutward, .alignMinYOutward, .alignMaxYOutward]
            )
            tileContainers[index].isHidden = layout.container.isEmpty
            displayLayers[index].display()
        }
    }

    override var acceptsFirstResponder: Bool { true }

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

    override func scrollWheel(with event: NSEvent) {
        guard let input, let point = remotePoint(for: event) ?? lastRemotePoint else { return }
        scrollRemainder += event.scrollingDeltaY
        let wholeTicks = Int(scrollRemainder)
        guard wholeTicks != 0 else { return }
        scrollRemainder -= CGFloat(wholeTicks)
        enqueueInput {
            await input.scroll(
                up: wholeTicks > 0,
                ticks: abs(wholeTicks),
                x: point.x,
                y: point.y
            )
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard let input, let modifier = AppleKeySymbol.modifier(for: event.keyCode) else { return }
        let isDown: Bool
        if activeModifiers[event.keyCode] != nil {
            activeModifiers.removeValue(forKey: event.keyCode)
            isDown = false
        } else if event.modifierFlags.contains(modifier.flag) {
            activeModifiers[event.keyCode] = modifier.symbol
            isDown = true
        } else {
            return
        }
        enqueueInput { await input.key(isDown: isDown, symbol: modifier.symbol) }
    }

    override func keyDown(with event: NSEvent) {
        guard let input else { return }
        if let symbol = AppleKeySymbol.special[event.keyCode] {
            enqueueInput { await input.key(isDown: true, symbol: symbol) }
            return
        }
        let hasCommandModifier = !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        let characters = hasCommandModifier ? event.charactersIgnoringModifiers : event.characters
        guard let symbols = characters?.unicodeScalars.map(\.value), !symbols.isEmpty else { return }
        enqueueInput {
            for symbol in symbols {
                await input.key(isDown: true, symbol: symbol)
                if !hasCommandModifier { await input.key(isDown: false, symbol: symbol) }
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let input else { return }
        if let symbol = AppleKeySymbol.special[event.keyCode] {
            enqueueInput { await input.key(isDown: false, symbol: symbol) }
            return
        }
        guard !event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let symbols = event.charactersIgnoringModifiers?.unicodeScalars.map(\.value) else { return }
        enqueueInput { for symbol in symbols { await input.key(isDown: false, symbol: symbol) } }
    }

    override func resignFirstResponder() -> Bool {
        if let input {
            let modifiers = Array(activeModifiers.values)
            activeModifiers.removeAll()
            let shouldReleasePointer = buttonMask != 0
            buttonMask = 0
            let point = lastRemotePoint
            enqueueInput {
                for symbol in modifiers { await input.key(isDown: false, symbol: symbol) }
                if shouldReleasePointer, let point {
                    await input.pointer(buttons: 0, x: point.x, y: point.y)
                }
            }
        }
        return super.resignFirstResponder()
    }

    private func sendPointer(_ event: NSEvent) {
        guard let input, let point = remotePoint(for: event) else { return }
        lastRemotePoint = point
        let buttons = buttonMask
        enqueueInput { await input.pointer(buttons: buttons, x: point.x, y: point.y) }
    }

    private func enqueueInput(_ operation: @escaping @Sendable () async -> Void) {
        let previous = inputTask
        inputTask = Task {
            _ = await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    private func remotePoint(for event: NSEvent) -> (x: Int, y: Int)? {
        AppleVideoCanvasLayout.remotePoint(
            location: convert(event.locationInWindow, from: nil),
            canvas: canvas,
            bounds: bounds,
            fixedScale: displayScale.fixedScale
        )
    }

    private func display(_ pixelBuffer: CVPixelBuffer, at tileIndex: Int) {
        precondition(Thread.isMainThread)
        guard displayLayers.indices.contains(tileIndex) else { return }
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        if decodedTileHeight != height {
            decodedTileHeight = height
            needsLayout = true
        }

        (displayLayers[tileIndex] as? AppleNV24MetalLayer)?.present(pixelBuffer)
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

}

enum AppleVideoCanvasLayout {
    struct Tile: Equatable {
        let container: CGRect
        let content: CGRect
    }

    static func tiles(
        canvas: AppleCanvas,
        bounds: CGRect,
        slotHeight: CGFloat,
        fixedScale: CGFloat?
    ) -> [Tile] {
        guard canvas.tileCount > 0, canvas.width > 0, canvas.height > 0, slotHeight > 0 else {
            return []
        }
        let canvasSize = CGSize(width: canvas.width, height: canvas.height)
        let scale = fixedScale
            ?? min(bounds.width / canvasSize.width, bounds.height / canvasSize.height)
        let outputSize = CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
        let canvasRect = CGRect(
            x: bounds.midX - outputSize.width / 2,
            y: bounds.midY - outputSize.height / 2,
            width: outputSize.width,
            height: outputSize.height
        )
        return (0..<canvas.tileCount).map { tileIndex in
            let pixelOrigin = CGFloat(tileIndex) * slotHeight
            let visibleHeight = min(slotHeight, max(0, canvasSize.height - pixelOrigin))
            guard visibleHeight > 0 else { return Tile(container: .zero, content: .zero) }
            let container = CGRect(
                x: canvasRect.minX,
                y: canvasRect.maxY - (pixelOrigin + visibleHeight) * scale,
                width: canvasRect.width,
                height: visibleHeight * scale
            )
            let content = CGRect(
                x: 0,
                y: -(slotHeight - visibleHeight) * scale,
                width: container.width,
                height: slotHeight * scale
            )
            return Tile(container: container, content: content)
        }
    }

    static func remotePoint(
        location: CGPoint,
        canvas: AppleCanvas,
        bounds: CGRect,
        fixedScale: CGFloat?
    ) -> (x: Int, y: Int)? {
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        let scale = fixedScale
            ?? min(bounds.width / CGFloat(canvas.width), bounds.height / CGFloat(canvas.height))
        guard scale > 0 else { return nil }
        let size = CGSize(width: CGFloat(canvas.width) * scale, height: CGFloat(canvas.height) * scale)
        let rect = CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        guard rect.contains(location) else { return nil }
        return (
            min(canvas.width - 1, max(0, Int((location.x - rect.minX) / scale))),
            min(canvas.height - 1, max(0, Int((rect.maxY - location.y) / scale)))
        )
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
