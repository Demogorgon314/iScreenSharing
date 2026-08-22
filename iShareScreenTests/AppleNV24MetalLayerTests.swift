import XCTest
@testable import iShareScreen

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

    func testAppEnablesMetalHUDRuntimeForLayerToggle() {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "MetalHudEnabled") as? Bool,
            true
        )
    }

    func testDisplaySchedulerPresentsLatestFrameOncePerDisplayLinkUpdate() {
        var scheduler = AppleVideoDisplayScheduler()
        var presentationCount = 0

        scheduler.markNeedsPresentation()
        scheduler.markNeedsPresentation()
        scheduler.displayLinkDidFire {
            presentationCount += 1
            return true
        }
        scheduler.displayLinkDidFire {
            presentationCount += 1
            return true
        }

        XCTAssertEqual(presentationCount, 1)
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

    func testVideoCanvasUsesDisplayLinkPacingWithMetalSynchronization() throws {
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
}
