import XCTest
@testable import iScreenSharing

@MainActor
final class AppleNV24MetalLayerTests: XCTestCase {
    func testCreatesMetalRenderingContext() {
        XCTAssertNotNil(AppleNV24MetalContext())
    }

    func testConfiguresDisplaySyncWithoutTransactionPresentation() throws {
        let context = try XCTUnwrap(AppleNV24MetalContext())
        let layer = AppleNV24MetalLayer(context: context)

        XCTAssertTrue(layer.displaySyncEnabled)
        XCTAssertFalse(layer.presentsWithTransaction)
        XCTAssertEqual(layer.maximumDrawableCount, 2)
        XCTAssertTrue(layer.allowsNextDrawableTimeout)

        layer.synchronizesPresentation = false
        XCTAssertFalse(layer.displaySyncEnabled)
        XCTAssertFalse(layer.presentsWithTransaction)
    }

    func testConfiguresDeveloperHUDPerMetalLayer() throws {
        let context = try XCTUnwrap(AppleNV24MetalContext())
        let layer = AppleNV24MetalLayer(context: context)

        XCTAssertEqual(layer.developerHUDProperties?["mode"] as? String, "disabled")

        layer.showsDeveloperHUD = true

        XCTAssertEqual(layer.developerHUDProperties?["mode"] as? String, "default")
    }

    func testPresentationLayerCopyDoesNotRegisterDeveloperHUD() throws {
        let context = try XCTUnwrap(AppleNV24MetalContext())
        let layer = AppleNV24MetalLayer(context: context, showsDeveloperHUD: true)

        let presentationCopy = AppleNV24MetalLayer(layer: layer)

        XCTAssertFalse(presentationCopy.showsDeveloperHUD)
        XCTAssertEqual(
            presentationCopy.developerHUDProperties?["mode"] as? String,
            "disabled"
        )
    }

    func testSnapshotRequiresAFrame() throws {
        let context = try XCTUnwrap(AppleNV24MetalContext())
        let layer = AppleNV24MetalLayer(context: context)
        layer.bounds = CGRect(x: 0, y: 0, width: 8, height: 4)
        layer.contentsScale = 1
        layer.update(
            layouts: [],
            fullCanvasLayout: AppleVideoCanvasLayout.Tile(
                container: layer.bounds,
                content: layer.bounds
            ),
            canvasSize: layer.bounds.size,
            bounds: layer.bounds
        )

        XCTAssertNil(layer.snapshot())
    }

    func testSnapshotRendersTheCurrentFrameAtDrawableResolution() throws {
        let context = try XCTUnwrap(AppleNV24MetalContext())
        let layer = AppleNV24MetalLayer(context: context)
        layer.bounds = CGRect(x: 0, y: 0, width: 8, height: 4)
        layer.contentsScale = 2
        layer.update(
            layouts: [],
            fullCanvasLayout: AppleVideoCanvasLayout.Tile(
                container: layer.bounds,
                content: layer.bounds
            ),
            canvasSize: layer.bounds.size,
            bounds: layer.bounds
        )
        layer.update(
            makeFrame(pixelBuffer: try makeNV24PixelBuffer(width: 8, height: 4)),
            at: AppleVideoFrameStore.fullCanvasIndex
        )

        let image = try XCTUnwrap(layer.snapshot())

        XCTAssertEqual(image.width, 16)
        XCTAssertEqual(image.height, 8)
        let pixels = try XCTUnwrap(image.dataProvider?.data as Data?)
        XCTAssertGreaterThan(pixels[0], 0)
        XCTAssertEqual(pixels[3], 255)
    }

    func testTiledSnapshotCompositesAtCanvasResolutionBeforeScaling() throws {
        let context = try XCTUnwrap(AppleNV24MetalContext())
        let layer = AppleNV24MetalLayer(context: context)
        let canvas = AppleCanvas(width: 8, height: 4, tileCount: 2)
        layer.bounds = CGRect(x: 0, y: 0, width: 13, height: 9)
        layer.contentsScale = 1
        layer.update(
            layouts: AppleVideoCanvasLayout.tiles(
                canvas: canvas,
                bounds: layer.bounds,
                slotHeight: 2,
                fixedScale: nil,
                stretchesToFillBounds: true
            ),
            fullCanvasLayout: AppleVideoCanvasLayout.fullCanvas(
                canvas: canvas,
                bounds: layer.bounds,
                fixedScale: nil,
                stretchesToFillBounds: true
            ),
            canvasSize: CGSize(width: canvas.width, height: canvas.height),
            bounds: layer.bounds
        )
        layer.update(
            makeFrame(pixelBuffer: try makeNV24PixelBuffer(width: 8, height: 2)),
            at: 0
        )
        layer.update(
            makeFrame(pixelBuffer: try makeNV24PixelBuffer(width: 8, height: 2)),
            at: 1
        )

        let image = try XCTUnwrap(layer.snapshot())
        let pixels = try XCTUnwrap(image.dataProvider?.data as Data?)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            XCTAssertGreaterThan(pixels[offset], 0)
            XCTAssertEqual(pixels[offset + 3], 255)
        }
    }

    func testSwitchingFromPaddedFullCanvasToTilesRestoresCanvasGeometry() async throws {
        let frames = AppleVideoFrameStore()
        let view = RemoteVideoCanvasNSView(
            canvas: AppleCanvas(width: 8, height: 4, tileCount: 2),
            frames: frames,
            input: nil,
            cursors: nil,
            displayScale: AppleVideoDisplayScale(),
            synchronizesPresentation: false,
            sourceRect: nil,
            inputMapping: nil,
            inputCoordinatesAreDisplayLocal: false,
            inputDisplayID: nil
        )
        view.frame = CGRect(x: 0, y: 0, width: 8, height: 4)
        view.layoutSubtreeIfNeeded()
        let metalLayer = try XCTUnwrap(
            view.layer?.sublayers?.compactMap { $0 as? AppleNV24MetalLayer }.first
        )
        metalLayer.contentsScale = 1
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()

        let fullCanvasDelivered = expectation(description: "padded VCP frame delivered")
        let fullCanvasObserver = frames.addObserver { batch in
            if batch[AppleVideoFrameStore.fullCanvasIndex] != nil {
                fullCanvasDelivered.fulfill()
            }
        }
        frames.publish(
            try makeNV24PixelBuffer(width: 8, height: 6),
            at: AppleVideoFrameStore.fullCanvasIndex
        )
        await fulfillment(of: [fullCanvasDelivered], timeout: 1)
        frames.removeObserver(fullCanvasObserver)

        let tilesDelivered = expectation(description: "VideoToolbox tiles delivered")
        let tileObserver = frames.addObserver { batch in
            if batch[0] != nil, batch[1] != nil { tilesDelivered.fulfill() }
        }
        frames.publish(try makeNV24PixelBuffer(width: 8, height: 2, luma: 32), at: 0)
        frames.publish(try makeNV24PixelBuffer(width: 8, height: 2, luma: 224), at: 1)
        await fulfillment(of: [tilesDelivered], timeout: 1)
        frames.removeObserver(tileObserver)

        let image = try XCTUnwrap(metalLayer.snapshot())
        XCTAssertEqual(image.height, 4)
        let pixels = try XCTUnwrap(image.dataProvider?.data as Data?)
        let rowAverages = (0..<image.height).map { row in
            let rowStart = row * image.bytesPerRow
            let blueValues = stride(from: rowStart, to: rowStart + image.width * 4, by: 4)
                .map { Int(pixels[$0]) }
            return blueValues.reduce(0, +) / blueValues.count
        }
        XCTAssertEqual(rowAverages.filter { $0 > 128 }.count, 2)
        XCTAssertEqual(rowAverages.filter { $0 < 128 }.count, 2)
    }

    func testAppEnablesMetalHUDRuntimeForLayerToggle() {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "MetalHudEnabled") as? Bool,
            true
        )
    }

    func testDisplaySchedulerPresentsLatestFrameOncePerDisplayLinkUpdate() {
        var scheduler = AppleVideoDisplayScheduler()
        var presentationCount = 0
        var receivedTargetTimestamp: TimeInterval?

        scheduler.markNeedsPresentation()
        scheduler.markNeedsPresentation()
        let firstUpdate = scheduler.displayLinkDidFire(targetTimestamp: 42)
        XCTAssertTrue(firstUpdate.frames.isEmpty)
        if firstUpdate.requiresPresentation {
            presentationCount += 1
            receivedTargetTimestamp = 42
        }
        let secondUpdate = scheduler.displayLinkDidFire(targetTimestamp: 43)
        XCTAssertTrue(secondUpdate.frames.isEmpty)
        if secondUpdate.requiresPresentation {
            presentationCount += 1
        }

        XCTAssertEqual(presentationCount, 1)
        XCTAssertEqual(receivedTargetTimestamp, 42)
    }

    func testVideoCanvasUsesOneMetalLayerForAllTiles() {
        let view = RemoteVideoCanvasNSView(
            canvas: AppleCanvas(width: 1920, height: 1080, tileCount: 4),
            frames: AppleVideoFrameStore(),
            input: nil,
            cursors: nil,
            displayScale: AppleVideoDisplayScale(),
            synchronizesPresentation: true,
            sourceRect: nil,
            inputMapping: nil,
            inputCoordinatesAreDisplayLocal: false,
            inputDisplayID: nil
        )

        XCTAssertEqual(
            view.layer?.sublayers?.filter { $0 is AppleNV24MetalLayer }.count,
            1
        )
    }

    func testVideoCanvasKeepsMetalLayerAfterLiveResizeWhenHUDIsVisible() throws {
        let view = RemoteVideoCanvasNSView(
            canvas: AppleCanvas(width: 1920, height: 1080, tileCount: 4),
            frames: AppleVideoFrameStore(),
            input: nil,
            cursors: nil,
            displayScale: AppleVideoDisplayScale(),
            synchronizesPresentation: true,
            showsDeveloperHUD: true,
            sourceRect: nil,
            inputMapping: nil,
            inputCoordinatesAreDisplayLocal: false,
            inputDisplayID: nil
        )
        let originalLayer = try XCTUnwrap(
            view.layer?.sublayers?.compactMap { $0 as? AppleNV24MetalLayer }.first
        )

        view.viewWillStartLiveResize()
        view.setFrameSize(NSSize(width: 800, height: 450))
        view.layoutSubtreeIfNeeded()
        view.viewDidEndLiveResize()

        let retainedLayer = try XCTUnwrap(
            view.layer?.sublayers?.compactMap { $0 as? AppleNV24MetalLayer }.first
        )
        XCTAssertTrue(originalLayer === retainedLayer)
        XCTAssertEqual(retainedLayer.developerHUDProperties?["mode"] as? String, "default")
    }

    func testVideoCanvasReportsLiveResizeLifecycleWithFinalViewport() {
        var events = [(isResizing: Bool, viewport: CGSize)]()
        let view = RemoteVideoCanvasNSView(
            canvas: AppleCanvas(width: 1920, height: 1080, tileCount: 4),
            frames: AppleVideoFrameStore(),
            input: nil,
            cursors: nil,
            displayScale: AppleVideoDisplayScale(),
            synchronizesPresentation: true,
            sourceRect: nil,
            inputMapping: nil,
            inputCoordinatesAreDisplayLocal: false,
            inputDisplayID: nil,
            onLiveResizeChange: { events.append(($0, $1)) }
        )

        view.setFrameSize(NSSize(width: 700, height: 450))
        view.viewWillStartLiveResize()
        view.setFrameSize(NSSize(width: 900, height: 600))
        view.viewDidEndLiveResize()

        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events[0].isResizing)
        XCTAssertEqual(events[0].viewport, CGSize(width: 700, height: 450))
        XCTAssertFalse(events[1].isResizing)
        XCTAssertEqual(events[1].viewport, CGSize(width: 900, height: 600))
    }

    func testVideoCanvasUpdatesResolutionWithoutReplacingMetalLayer() throws {
        let view = RemoteVideoCanvasNSView(
            canvas: AppleCanvas(width: 1920, height: 1080, tileCount: 4),
            frames: AppleVideoFrameStore(),
            input: nil,
            cursors: nil,
            displayScale: AppleVideoDisplayScale(),
            synchronizesPresentation: true,
            showsDeveloperHUD: true,
            sourceRect: nil,
            inputMapping: nil,
            inputCoordinatesAreDisplayLocal: false,
            inputDisplayID: nil
        )
        let originalLayer = try XCTUnwrap(
            view.layer?.sublayers?.compactMap { $0 as? AppleNV24MetalLayer }.first
        )

        view.update(canvas: AppleCanvas(width: 2560, height: 1440, tileCount: 4))
        view.layoutSubtreeIfNeeded()

        let retainedLayer = try XCTUnwrap(
            view.layer?.sublayers?.compactMap { $0 as? AppleNV24MetalLayer }.first
        )
        XCTAssertTrue(originalLayer === retainedLayer)
        XCTAssertEqual(view.canvas, AppleCanvas(width: 2560, height: 1440, tileCount: 4))
        XCTAssertEqual(retainedLayer.developerHUDProperties?["mode"] as? String, "default")
    }

    func testReconnectReusesTheOriginalDeveloperHUDMetalLayer() throws {
        let renderer = AppleVideoRenderer()
        let firstView = RemoteVideoCanvasNSView(
            renderer: renderer,
            canvas: AppleCanvas(width: 1920, height: 1080, tileCount: 4),
            frames: AppleVideoFrameStore(),
            input: nil,
            cursors: nil,
            displayScale: AppleVideoDisplayScale(),
            synchronizesPresentation: true,
            showsDeveloperHUD: true,
            sourceRect: nil,
            inputMapping: nil,
            inputCoordinatesAreDisplayLocal: false,
            inputDisplayID: nil
        )
        let firstLayer = try XCTUnwrap(
            firstView.layer?.sublayers?.compactMap { $0 as? AppleNV24MetalLayer }.first
        )
        XCTAssertEqual(firstLayer.developerHUDProperties?["mode"] as? String, "default")
        RemoteVideoCanvasView.dismantleNSView(firstView, coordinator: ())

        let secondView = RemoteVideoCanvasNSView(
            renderer: renderer,
            canvas: AppleCanvas(width: 1920, height: 1080, tileCount: 4),
            frames: AppleVideoFrameStore(),
            input: nil,
            cursors: nil,
            displayScale: AppleVideoDisplayScale(),
            synchronizesPresentation: true,
            showsDeveloperHUD: true,
            sourceRect: nil,
            inputMapping: nil,
            inputCoordinatesAreDisplayLocal: false,
            inputDisplayID: nil
        )
        let secondLayer = try XCTUnwrap(
            secondView.layer?.sublayers?.compactMap { $0 as? AppleNV24MetalLayer }.first
        )
        XCTAssertTrue(firstLayer === secondLayer)
        XCTAssertEqual(secondLayer.developerHUDProperties?["mode"] as? String, "default")
    }

    func testSessionWindowCoordinatorRetainsRendererAcrossWindowRecreation() throws {
        let coordinator = SessionWindowCoordinator()
        let endpoint = try ConnectionEndpoint(host: "example.local")

        let firstWindowRenderer = coordinator.videoRenderer(for: endpoint, displayIndex: 0)
        let reopenedWindowRenderer = coordinator.videoRenderer(for: endpoint, displayIndex: 0)
        let auxiliaryWindowRenderer = coordinator.videoRenderer(for: endpoint, displayIndex: 1)

        XCTAssertTrue(firstWindowRenderer === reopenedWindowRenderer)
        XCTAssertFalse(firstWindowRenderer === auxiliaryWindowRenderer)
    }

    func testVideoCanvasKeepsMetalLayerAfterLiveResizeWhenHUDIsHidden() throws {
        let view = RemoteVideoCanvasNSView(
            canvas: AppleCanvas(width: 1920, height: 1080, tileCount: 4),
            frames: AppleVideoFrameStore(),
            input: nil,
            cursors: nil,
            displayScale: AppleVideoDisplayScale(),
            synchronizesPresentation: true,
            sourceRect: nil,
            inputMapping: nil,
            inputCoordinatesAreDisplayLocal: false,
            inputDisplayID: nil
        )
        let originalLayer = try XCTUnwrap(
            view.layer?.sublayers?.compactMap { $0 as? AppleNV24MetalLayer }.first
        )

        view.viewWillStartLiveResize()
        view.setFrameSize(NSSize(width: 800, height: 450))
        view.layoutSubtreeIfNeeded()
        view.viewDidEndLiveResize()

        let retainedLayer = try XCTUnwrap(
            view.layer?.sublayers?.compactMap { $0 as? AppleNV24MetalLayer }.first
        )
        XCTAssertTrue(originalLayer === retainedLayer)
    }

    func testMetalLayerExplicitlyDisablesGeometryAnimations() throws {
        let view = RemoteVideoCanvasNSView(
            canvas: AppleCanvas(width: 1920, height: 1080, tileCount: 4),
            frames: AppleVideoFrameStore(),
            input: nil,
            cursors: nil,
            displayScale: AppleVideoDisplayScale(),
            stretchesVideoToFillBounds: true,
            synchronizesPresentation: true,
            sourceRect: nil,
            inputMapping: nil,
            inputCoordinatesAreDisplayLocal: false,
            inputDisplayID: nil
        )
        let metalLayer = try XCTUnwrap(
            view.layer?.sublayers?.compactMap { $0 as? AppleNV24MetalLayer }.first
        )
        XCTAssertTrue(metalLayer.actions?["bounds"] is NSNull)
        XCTAssertTrue(metalLayer.actions?["position"] is NSNull)
    }

    func testVideoCanvasUsesDisplayLinkAdmissionWithImmediateMetalSynchronization() throws {
        let view = RemoteVideoCanvasNSView(
            canvas: AppleCanvas(width: 1920, height: 1080, tileCount: 4),
            frames: AppleVideoFrameStore(),
            input: nil,
            cursors: nil,
            displayScale: AppleVideoDisplayScale(),
            synchronizesPresentation: true,
            sourceRect: nil,
            inputMapping: nil,
            inputCoordinatesAreDisplayLocal: false,
            inputDisplayID: nil
        )
        let metalLayer = try XCTUnwrap(
            view.layer?.sublayers?.compactMap { $0 as? AppleNV24MetalLayer }.first
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view

        XCTAssertTrue(view.usesSynchronizedDisplayLink)
        XCTAssertTrue(metalLayer.displaySyncEnabled)

        view.synchronizesPresentation = false
        XCTAssertFalse(view.usesSynchronizedDisplayLink)
        XCTAssertFalse(metalLayer.displaySyncEnabled)
    }

    func testChangingWindowScreenResetsCadenceWithoutReplacingMetalLayer() throws {
        let renderer = AppleVideoRenderer()
        let performance = AppleVideoPerformanceMonitor(
            tileCount: 4,
            clock: { 0 },
            automaticallyPublishes: false
        )
        let view = RemoteVideoCanvasNSView(
            renderer: renderer,
            canvas: AppleCanvas(width: 1920, height: 1080, tileCount: 4),
            frames: AppleVideoFrameStore(),
            input: nil,
            cursors: nil,
            displayScale: AppleVideoDisplayScale(),
            synchronizesPresentation: true,
            sourceRect: nil,
            inputMapping: nil,
            inputCoordinatesAreDisplayLocal: false,
            inputDisplayID: nil,
            performance: performance
        )
        let originalLayer = try XCTUnwrap(
            view.layer?.sublayers?.compactMap { $0 as? AppleNV24MetalLayer }.first
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        performance.recordDisplay(duration: 0.003, presentedAt: 1.000)
        performance.recordDisplay(duration: 0.003, presentedAt: 1.007)

        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)

        let retainedLayer = try XCTUnwrap(
            view.layer?.sublayers?.compactMap { $0 as? AppleNV24MetalLayer }.first
        )
        XCTAssertTrue(originalLayer === retainedLayer)
        XCTAssertTrue(performance.sample(at: 1).recentDisplayFrameMilliseconds.isEmpty)
    }

    private func makeNV24PixelBuffer(
        width: Int,
        height: Int,
        luma: UInt8 = 128
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            AppleHEVCDecoder.nativePixelFormat,
            attributes,
            &pixelBuffer
        )
        let result = try XCTUnwrap(pixelBuffer, "CVPixelBufferCreate failed with \(status)")
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(result) {
            guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(result, plane) else { continue }
            memset(
                baseAddress,
                plane == 0 ? Int32(luma) : 128,
                CVPixelBufferGetBytesPerRowOfPlane(result, plane)
                    * CVPixelBufferGetHeightOfPlane(result, plane)
            )
        }
        return result
    }

    private func makeFrame(pixelBuffer: CVPixelBuffer) -> AppleVideoFrameStore.Frame {
        AppleVideoFrameStore.Frame(
            pixelBuffer: pixelBuffer,
            decodingOrderNumber: nil,
            rtpTimestamp: nil,
            accessUnitTiming: nil,
            decodeEnteredAt: 0,
            decoderSubmittedAt: 0,
            decoderOutputAt: 0,
            playbackHandledAt: 0,
            decodedAt: 0,
            presentationTime: 0,
            sequence: 1
        )
    }
}
