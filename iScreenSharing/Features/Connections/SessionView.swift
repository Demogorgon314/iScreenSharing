import SwiftUI

struct SessionView: View {
    let endpoint: ConnectionEndpoint
    @ObservedObject var sessions: SessionManager
    @ObservedObject var displayLayout: AppleDisplayLayoutModel
    @ObservedObject var dynamicResolution: AppleDynamicResolutionModel
    @ObservedObject var controlState: AppleSessionControlState
    @ObservedObject var commandState: SessionCommandState
    let displayIndex: Int
    let disconnectsSessionOnDisappear: Bool
    @State private var viewportSize = CGSize.zero
    @State private var isLiveResizing = false
    @State private var sessionWindowIdentifier = UUID()
    @State private var screenshotButtonAnchor: NSView?
    let videoRenderer: AppleVideoRenderer
    private let viewportStore = SessionViewportStore()

    private var isObserving: Bool { commandState.isObserving }
    private var isChangingMode: Bool { commandState.isChangingMode }

    var body: some View {
        Group {
            if let session = sessions.session(for: endpoint),
               let stream = session.videoStream(for: displayIndex) {
                let usesIndependentVideoStreams = session.videoStreams.count > 1
                ActiveVideoSessionView(
                    renderer: videoRenderer,
                    stream: stream,
                    input: isObserving ? nil : session.inputController,
                    fileTransfer: isObserving ? nil : session.fileTransferService,
                    cursors: session.cursorStore,
                    displayScale: commandState.displayScale,
                    stretchesVideoToFillBounds:
                        commandState.canUseDynamicResolution && commandState.usesDynamicResolution,
                    synchronizesPresentation: commandState.synchronizesVideoPresentation,
                    showsPerformanceOverlay: commandState.showsVideoPerformanceOverlay,
                    performanceLevel: commandState.videoPerformanceLevel,
                    showsMetalPerformanceHUD: commandState.showsMetalPerformanceHUD,
                    sourceRect: usesIndependentVideoStreams ? nil : displayLayout.sourceRect(for: displayIndex),
                    inputMapping: displayLayout.inputMapping(
                        for: displayIndex,
                        localSourceSize: usesIndependentVideoStreams
                            ? CGSize(width: stream.canvas.width, height: stream.canvas.height)
                            : nil
                    ),
                    inputCoordinatesAreDisplayLocal: usesIndependentVideoStreams,
                    inputDisplayID: nil,
                    onWindowKeyChange: { isKey in
                        session.clipboardService?.setSessionWindow(
                            sessionWindowIdentifier,
                            isKey: isKey
                        )
                    },
                    onLiveResizeChange: liveResizeChanged,
                    onViewportChange: viewportChanged
                )
                .onChange(of: stream.state) { _, state in
                    if state == .streaming { scheduleDynamicResolution() }
                }
            } else {
                unavailableContent
            }
        }
        .onDisappear {
            if disconnectsSessionOnDisappear {
                dynamicResolution.cancel()
                sessions.disconnect(endpoint)
            }
        }
        .navigationTitle(endpoint.displayName)
        .toolbar { sessionToolbar }
        .alert("Unable to Change Mode", isPresented: modeErrorIsPresented) {
            Button("OK") { controlState.clearError() }
        } message: {
            Text(controlState.errorMessage ?? "The Screen Sharing mode could not be changed.")
        }
        .alert("Unable to Change Resolution", isPresented: resolutionErrorIsPresented) {
            Button("OK") { dynamicResolution.clearError() }
        } message: {
            Text(dynamicResolution.errorMessage ?? "The remote display resolution could not be changed.")
        }
        .onChange(of: dynamicResolution.isEnabled) { _, enabled in
            if enabled { scheduleDynamicResolution() }
        }
        .onChange(of: displayLayout.layout) { _, _ in
            if commandState.canUseDynamicResolution {
                scheduleDynamicResolution()
            } else {
                dynamicResolution.cancel()
            }
        }
    }

    @ToolbarContentBuilder
    private var sessionToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { takeScreenshot() } label: {
                Label("Take Screenshot", systemImage: "camera")
            }
            .background {
                ScreenshotButtonAnchor(anchorView: $screenshotButtonAnchor)
            }
            .help("Take Screenshot")
            if let history = sessions.session(for: endpoint)?.fileTransferService?.history {
                FileTransferToolbarButton(history: history)
            }
            Button { commandState.setScalesToFit(!commandState.displayScale.scalesToFit) } label: {
                Label(
                    commandState.displayScale.scalesToFit ? "Turn Scaling Off" : "Turn Scaling On",
                    systemImage: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
                )
            }
            .help(commandState.displayScale.scalesToFit ? "Turn Scaling Off" : "Turn Scaling On")
            Menu {
                Toggle("Use Shared Clipboard", isOn: sharedClipboardBinding)
                    .disabled(!commandState.canToggleSharedClipboard)
                Divider()
                Button("Get Clipboard") { commandState.getClipboard() }
                    .disabled(!commandState.canGetOrSendClipboard)
                Button("Send Clipboard") { commandState.sendClipboard() }
                    .disabled(!commandState.canGetOrSendClipboard)
            } label: {
                Label(
                    "Clipboard",
                    systemImage: commandState.usesSharedClipboard
                        ? "doc.on.clipboard"
                        : "clipboard"
                )
            }
            .help("Clipboard Settings")
            .disabled(!commandState.canUseClipboard)
            if let capabilities = sessions.session(for: endpoint)?.remoteSystemCapabilities,
               sessions.session(for: endpoint)?.inputController != nil {
                RemoteSystemCommandButtons(
                    capabilities: capabilities,
                    isDisabled: isObserving || isChangingMode,
                    perform: performRemoteSystemCommand
                )
            }
            if let keyboardInputSource = sessions.session(for: endpoint)?.keyboardInputSourceService {
                KeyboardInputSourceButton(
                    service: keyboardInputSource,
                    isDisabled: isObserving || isChangingMode
                )
            }
            Button { commandState.setObserving(!isObserving) } label: {
                Label(
                    isObserving ? "Control" : "Observe",
                    systemImage: isObserving ? "eye.fill" : "cursorarrow.rays"
                )
            }
            .help(isObserving ? "Switch to Control Mode" : "Switch to Observe Mode")
            .disabled(isChangingMode || sessions.session(for: endpoint) == nil)
            Toggle(isOn: dynamicResolutionBinding) {
                Label("Dynamic Resolution", systemImage: "display")
            }
            .toggleStyle(.button)
            .help("Dynamic Resolution")
            .disabled(!commandState.canUseDynamicResolution)
            Toggle(isOn: videoSynchronizationBinding) {
                Label("Synchronize Video", systemImage: "arrow.triangle.2.circlepath")
            }
            .toggleStyle(.button)
            .help("Synchronize Video")
            Toggle(isOn: videoPerformanceBinding) {
                Label("Video Performance", systemImage: "chart.xyaxis.line")
            }
            .toggleStyle(.button)
            .help("Video Performance")
            Toggle(isOn: metalPerformanceHUDBinding) {
                Label("Metal Performance HUD", systemImage: "gauge.with.needle")
            }
            .toggleStyle(.button)
            .help("Metal Performance HUD")
            if let audio = sessions.session(for: endpoint)?.audioStream {
                AudioMuteButton(audio: audio)
            }
        }
    }

    private var unavailableContent: some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                Image(systemName: "display")
                    .font(.system(size: 44, weight: .thin))
                Text(endpoint.displayName).font(.title3)
                Text("The connection is no longer active.")
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
        }
    }

    private var videoSynchronizationBinding: Binding<Bool> {
        Binding(
            get: { commandState.synchronizesVideoPresentation },
            set: { commandState.setSynchronizesVideoPresentation($0) }
        )
    }

    private var videoPerformanceBinding: Binding<Bool> {
        Binding(
            get: { commandState.showsVideoPerformanceOverlay },
            set: { commandState.setShowsVideoPerformanceOverlay($0) }
        )
    }

    private var metalPerformanceHUDBinding: Binding<Bool> {
        Binding(
            get: { commandState.showsMetalPerformanceHUD },
            set: { commandState.setShowsMetalPerformanceHUD($0) }
        )
    }

    private var dynamicResolutionBinding: Binding<Bool> {
        Binding(
            get: { commandState.usesDynamicResolution },
            set: { commandState.setUsesDynamicResolution($0) }
        )
    }

    private var sharedClipboardBinding: Binding<Bool> {
        Binding(
            get: { commandState.usesSharedClipboard },
            set: { commandState.setUsesSharedClipboard($0) }
        )
    }

    private var modeErrorIsPresented: Binding<Bool> {
        Binding(
            get: { controlState.errorMessage != nil },
            set: { if !$0 { controlState.clearError() } }
        )
    }

    private var resolutionErrorIsPresented: Binding<Bool> {
        Binding(
            get: { dynamicResolution.errorMessage != nil },
            set: { if !$0 { dynamicResolution.clearError() } }
        )
    }

    private func viewportChanged(_ size: CGSize) {
        viewportSize = size
        viewportStore.save(size, for: endpoint, displayIndex: displayIndex)
        guard !isLiveResizing else { return }
        scheduleDynamicResolution()
    }

    private func liveResizeChanged(_ isResizing: Bool, _ size: CGSize) {
        viewportSize = size
        viewportStore.save(size, for: endpoint, displayIndex: displayIndex)
        isLiveResizing = isResizing
        if isResizing {
            if dynamicResolution.isEnabled { dynamicResolution.cancel() }
        } else {
            scheduleDynamicResolution(waitsForViewportToSettle: false)
        }
    }

    private func scheduleDynamicResolution(waitsForViewportToSettle: Bool = true) {
        guard !isLiveResizing,
              commandState.canUseDynamicResolution,
              let session = sessions.session(for: endpoint),
              session.videoStream(for: displayIndex)?.state == .streaming,
              let controller = session.dynamicResolutionController else { return }
        dynamicResolution.schedule(
            displayIndex: displayIndex,
            viewport: viewportSize,
            canvas: session.videoStream(for: displayIndex)?.canvas,
            layout: displayLayout.layout,
            controller: controller,
            waitsForViewportToSettle: waitsForViewportToSettle
        )
    }

    private func performRemoteSystemCommand(_ command: AppleRemoteSystemCommand) {
        commandState.perform(command)
    }

    private func takeScreenshot() {
        guard let anchorView = screenshotButtonAnchor,
              anchorView.window != nil,
              let image = videoRenderer.snapshot() else {
            NSSound.beep()
            return
        }
        do {
            try ScreenshotSharingCoordinator.show(
                image,
                suggestedName: "Screenshot \(endpoint.displayName)",
                relativeTo: anchorView
            )
        } catch {
            NSSound.beep()
        }
    }
}

private struct RemoteSystemCommandButtons: View {
    @ObservedObject var capabilities: AppleRemoteSystemCapabilities
    let isDisabled: Bool
    let perform: (AppleRemoteSystemCommand) -> Void

    var body: some View {
        ForEach(AppleRemoteSystemCommand.allCases, id: \.self) { command in
            Button {
                perform(command)
            } label: {
                Label(command.title, systemImage: command.systemImage)
            }
            .help(command.title)
            .disabled(isDisabled || !capabilities.supports(command))
        }
    }
}

private struct KeyboardInputSourceButton: View {
    @ObservedObject var service: AppleKeyboardInputSourceService
    let isDisabled: Bool

    var body: some View {
        Toggle(
            isOn: Binding(
                get: { service.isSharingEnabled },
                set: { service.setSharingEnabled($0) }
            )
        ) {
            Label(
                "Share Input Source",
                systemImage: service.serverUsesSecureInput
                    ? "keyboard.badge.ellipsis"
                    : "keyboard"
            )
        }
        .toggleStyle(.button)
        .help("Share Keyboard Input Source")
        .disabled(isDisabled || !service.isSupported)
    }
}

private struct AudioMuteButton: View {
    @ObservedObject var audio: AppleAudioStream

    var body: some View {
        Button { audio.toggleMute() } label: {
            Label(
                audio.isMuted ? "Unmute" : "Mute",
                systemImage: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
            )
        }
        .help(audio.isMuted ? "Unmute" : "Mute")
    }
}

private struct ActiveVideoSessionView: View {
    let renderer: AppleVideoRenderer
    @ObservedObject var stream: AppleVideoStream
    let input: AppleInputController?
    let fileTransfer: AppleFileTransferService?
    let cursors: AppleCursorStore?
    let displayScale: AppleVideoDisplayScale
    let stretchesVideoToFillBounds: Bool
    let synchronizesPresentation: Bool
    let showsPerformanceOverlay: Bool
    let performanceLevel: VideoPerformanceLevel
    let showsMetalPerformanceHUD: Bool
    let sourceRect: CGRect?
    let inputMapping: AppleDisplayInputMapping?
    let inputCoordinatesAreDisplayLocal: Bool
    let inputDisplayID: UInt32?
    let onWindowKeyChange: (Bool) -> Void
    let onLiveResizeChange: (Bool, CGSize) -> Void
    let onViewportChange: (CGSize) -> Void

    var body: some View {
        ZStack {
            Color.black
            RemoteVideoCanvasView(
                renderer: renderer,
                canvas: stream.canvas,
                frames: stream.frames,
                performance: stream.performance,
                input: input,
                fileTransfer: fileTransfer,
                cursors: cursors,
                displayScale: displayScale,
                stretchesVideoToFillBounds: stretchesVideoToFillBounds,
                synchronizesPresentation: synchronizesPresentation,
                showsDeveloperHUD: showsMetalPerformanceHUD,
                sourceRect: sourceRect,
                inputMapping: inputMapping,
                inputCoordinatesAreDisplayLocal: inputCoordinatesAreDisplayLocal,
                inputDisplayID: inputDisplayID,
                onWindowKeyChange: onWindowKeyChange,
                onLiveResizeChange: onLiveResizeChange
            )
            if showsPerformanceOverlay {
                AppleVideoPerformanceOverlay(
                    performance: stream.performance,
                    canvas: stream.canvas,
                    level: performanceLevel
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
                    .allowsHitTesting(false)
            }
            if shouldShowStatusOverlay {
                Color.black
                    .overlay {
                        VStack(spacing: 10) {
                            if stream.state == .preparing { ProgressView().controlSize(.small) }
                            Text(statusMessage)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(20)
                    }
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { onViewportChange(geometry.size) }
                    .onChange(of: geometry.size) { _, size in onViewportChange(size) }
            }
        }
        .onAppear { updatePipelineDiagnosticsCollection() }
        .onChange(of: showsPerformanceOverlay) { _, _ in updatePipelineDiagnosticsCollection() }
        .onChange(of: performanceLevel) { _, _ in updatePipelineDiagnosticsCollection() }
    }

    private func updatePipelineDiagnosticsCollection() {
        stream.performance.setPipelineDiagnosticsEnabled(
            showsPerformanceOverlay && performanceLevel == .detailed
        )
    }

    private var shouldShowStatusOverlay: Bool {
        switch stream.state {
        case .preparing:
            stream.decodedFrameCount == 0
        case .streaming:
            false
        case .failed, .stopped:
            true
        }
    }

    private var statusMessage: String {
        switch stream.state {
        case .preparing: "Preparing the remote display…"
        case .streaming: ""
        case .failed(let message): message
        case .stopped: "The connection is no longer active."
        }
    }
}

private struct AppleVideoPerformanceOverlay: View {
    @ObservedObject var performance: AppleVideoPerformanceMonitor
    let canvas: AppleCanvas
    let level: VideoPerformanceLevel

    var body: some View {
        let stats = performance.snapshot
        let latency = stats.pipelineLatency
        VStack(alignment: .leading, spacing: 3) {
            if level == .compact {
                compactMetrics(stats)
            } else {
                standardMetrics(stats, latency: latency)
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(.black.opacity(0.74), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 0.5)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Video performance statistics")
    }

    @ViewBuilder
    private func standardMetrics(
        _ stats: AppleVideoPerformanceSnapshot,
        latency: AppleVideoPipelineLatencySnapshot
    ) -> some View {
            Text(String(
                format: "Network  %.1f Mb/s  %.0f pkt/s",
                stats.networkMegabitsPerSecond,
                stats.networkPacketsPerSecond
            ))
            if level == .detailed {
                Text(String(
                    format: "Socket   %.0f KB  queue %.0f KB/%.2f ms",
                    Double(stats.socketReceiveBufferBytes) / 1_024,
                    Double(stats.maximumSocketBacklogBytes) / 1_024,
                    stats.maximumReceiveDrainMilliseconds
                ))
                Text(String(
                    format: "Ingress  %@  %.2f/%.2f/%.2f/%.2f ms  overflow %llu",
                    stats.networkPath.rawValue,
                    stats.ingressAge.p50Milliseconds,
                    stats.ingressAge.p95Milliseconds,
                    stats.ingressAge.p99Milliseconds,
                    stats.ingressAge.maximumMilliseconds,
                    stats.receiveBufferOverflowPackets
                ))
                Text(String(
                    format: "RR       %.2f%% loss  %d total  %.2f ms jitter",
                    stats.receiverReportLossPercentage,
                    stats.cumulativePacketsLost,
                    stats.interarrivalJitterMilliseconds
                ))
            }
            Text(String(
                format: "Stream   %.1f AU/s  %.2f KB/AU",
                stats.accessUnitsPerSecond,
                stats.averageAccessUnitKilobytes
            ))
            Text(String(format: "Quality  IRAP %.1f/s", stats.intraRefreshesPerSecond))
            Text(String(
                format: "RCTL     %.1f/s  BWE %.1f Mb/s",
                stats.rateControlFeedbacksPerSecond,
                stats.estimatedReceiveBandwidthMegabitsPerSecond
            ))
            Text("Decoder  \(stats.decoderBackend?.rawValue ?? "—")")
            Text(String(
                format: "Decode   %.1f fps  %.2f ms",
                stats.decodedFramesPerSecond,
                stats.averageDecodeMilliseconds
            ))
            Text(String(
                format: "Submit   %.1f fps  %.2f ms",
                stats.presentedFramesPerSecond,
                stats.averagePresentationMilliseconds
            ))
            Text(String(
                format: "Display  %.1f fps  %.2f ms",
                stats.displayedFramesPerSecond,
                stats.averageDisplayMilliseconds
            ))
            Text(String(
                format: "Frame    %.2f ms  P95 %.2f ms",
                stats.averageDisplayFrameMilliseconds,
                stats.p95DisplayFrameMilliseconds
            ))
            AppleVideoFrameTimeGraph(
                samples: stats.recentDisplayFrameMilliseconds,
                average: stats.averageDisplayFrameMilliseconds,
                p95: stats.p95DisplayFrameMilliseconds,
                jitter: stats.displayCadenceJitterMilliseconds,
                refreshPeriod: stats.averageDisplayLinkPeriodMilliseconds
            )
            Text(String(
                format: "Jitter   %.2f ms  GPU %.2f ms",
                stats.displayCadenceJitterMilliseconds,
                stats.averageGPUMilliseconds
            ))
            Text(String(
                format: "VSync    %.2f/%.2f ms",
                stats.averageDisplayLinkLeadMilliseconds,
                stats.averageDisplayLinkPeriodMilliseconds
            ))
            Text(String(
                format: "Tile     %.2f ms  DON %d",
                stats.maximumTileSkewMilliseconds,
                stats.maximumDecodingOrderSpan
            ))
            Text(String(
                format: "Recovery NACK %d  FIR %d  Busy %d",
                stats.nackCount,
                stats.keyFrameRequestCount,
                stats.rendererBusyCount
            ))
            if level == .detailed {
                Text(String(
                    format: "AU       span %.2f  asm %.2f  queue %.2f ms",
                    latency.datagramSpanMilliseconds.p95,
                    latency.completingDatagramToAssemblyMilliseconds.p95,
                    latency.assemblyToDecodeEntryMilliseconds.p95
                ))
                Text(String(
                    format: "Decode   prep %.2f  decoder %.2f ms",
                    latency.decodeEntryToSubmitMilliseconds.p95,
                    latency.decoderSubmitToCallbackMilliseconds.p95
                ))
                Text(String(
                    format: "CB→PB    %.2f/%.2f/%.2f ms",
                    latency.decoderCallbackToPlaybackMilliseconds.p50,
                    latency.decoderCallbackToPlaybackMilliseconds.p95,
                    latency.decoderCallbackToPlaybackMilliseconds.maximum
                ))
                Text(String(
                    format: "PB→Main  %.2f/%.2f/%.2f ms",
                    latency.playbackToMainMilliseconds.p50,
                    latency.playbackToMainMilliseconds.p95,
                    latency.playbackToMainMilliseconds.maximum
                ))
                Text(String(
                    format: "Schedule %.2f/%.2f + %.2f/%.2f ms",
                    latency.mainToSchedulerMilliseconds.p50,
                    latency.mainToSchedulerMilliseconds.p95,
                    latency.schedulerToDrawableMilliseconds.p50,
                    latency.schedulerToDrawableMilliseconds.p95
                ))
                Text(String(
                    format: "Drawable %.2f/%.2f  Encode %.2f/%.2f ms",
                    latency.drawableWaitMilliseconds.p50,
                    latency.drawableWaitMilliseconds.p95,
                    latency.encodeMilliseconds.p50,
                    latency.encodeMilliseconds.p95
                ))
                Text(String(
                    format: "Metal    T %.2f  S %.2f  Q %.2f  GPU %.2f ms",
                    latency.encodeEndToCommitMilliseconds.p95,
                    latency.commitToScheduledCallbackMilliseconds.p95,
                    latency.gpuQueueWaitMilliseconds.p95,
                    latency.gpuExecutionMilliseconds.p95
                ))
                Text(String(
                    format: "Display  Scan %.2f  Commit %.2f ms",
                    latency.gpuEndToDisplayMilliseconds.p95,
                    latency.commitToDisplayMilliseconds.p95
                ))
                Text(String(
                    format: "Target   C %+.2f  G %+.2f  D %+.2f ms",
                    latency.commitLeadToTargetMilliseconds.p50,
                    latency.gpuEndLeadToTargetMilliseconds.p50,
                    latency.targetToDisplayMilliseconds.p50
                ))
                Text(String(
                    format: "Phase    %.2f periods  miss %d",
                    latency.targetPhasePeriods.p50,
                    latency.displayLinkMissCount
                ))
                Text(String(
                    format: "Socket→D %.2f/%.2f ms  Submit→D %.2f/%.2f ms",
                    latency.firstDatagramToDisplayMilliseconds.p50,
                    latency.firstDatagramToDisplayMilliseconds.p95,
                    latency.decoderSubmitToDisplayMilliseconds.p50,
                    latency.decoderSubmitToDisplayMilliseconds.p95
                ))
                Text(String(
                    format: "Batches  L/I %d/%d  E %d",
                    latency.displayLinkBatchCount,
                    latency.immediateBatchCount,
                    latency.traceEvictionCount
                ))
            }
    }

    @ViewBuilder
    private func compactMetrics(_ stats: AppleVideoPerformanceSnapshot) -> some View {
        Text(String(
            format: "%dx%d@%.0f HEVC 4:4:4/%@",
            canvas.width,
            canvas.height,
            stats.receivedFramesPerSecond,
            stats.decoderBackend?.rawValue ?? "—"
        ))
        Text(String(
            format: "FPS %.1f Rx · %.1f De · %.1f Rd",
            stats.receivedFramesPerSecond,
            stats.decodedFramesPerSecond,
            stats.presentedFramesPerSecond
        ))
        Text(String(
            format: "Network RTP loss %.2f%% · Video UDP %.1f Mb/s",
            stats.receiverReportLossPercentage,
            stats.networkMegabitsPerSecond
        ))
        Text(
            "Render \(formattedMilliseconds(stats.averageRenderCallMilliseconds, sampleCount: stats.renderCallSampleCount))"
                + " · Decode \(formattedMilliseconds(stats.averageAccessUnitToDecoderOutputMilliseconds, sampleCount: stats.accessUnitToDecoderOutputSampleCount))"
        )
    }

    private func formattedMilliseconds(_ value: Double, sampleCount: Int) -> String {
        guard sampleCount > 0 else { return "—" }
        return String(format: "%.2f ms", value)
    }
}

private struct AppleVideoFrameTimeGraph: View {
    let samples: [Double]
    let average: Double
    let p95: Double
    let jitter: Double
    let refreshPeriod: Double

    private static let capacity = 120

    var body: some View {
        Canvas { context, size in
            let visibleSamples = samples.suffix(Self.capacity)
            let scaleMaximum = max(33.34, max(p95 * 1.25, average * 1.75))
            let slotWidth = size.width / CGFloat(Self.capacity)
            let startX = size.width - CGFloat(visibleSamples.count) * slotWidth

            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(.white.opacity(0.055))
            )

            if average > 0 {
                let referenceY = size.height * CGFloat(1 - min(average / scaleMaximum, 1))
                var reference = Path()
                reference.move(to: CGPoint(x: 0, y: referenceY))
                reference.addLine(to: CGPoint(x: size.width, y: referenceY))
                context.stroke(
                    reference,
                    with: .color(.white.opacity(0.42)),
                    style: StrokeStyle(lineWidth: 0.5, dash: [2, 2])
                )
            }

            for (index, frameTime) in visibleSamples.enumerated() {
                let ratio = min(max(frameTime / scaleMaximum, 0), 1)
                let height = max(1, size.height * CGFloat(ratio))
                let rect = CGRect(
                    x: startX + CGFloat(index) * slotWidth,
                    y: size.height - height,
                    width: max(1, slotWidth - 0.5),
                    height: height
                )
                context.fill(
                    Path(rect),
                    with: .color(color(for: frameTime))
                )
            }
        }
        .frame(width: 244, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityLabel("Display frame time history")
        .accessibilityValue(String(
            format: "Average %.2f milliseconds, P95 %.2f milliseconds, jitter %.2f milliseconds",
            average,
            p95,
            jitter
        ))
    }

    private func color(for frameTime: Double) -> Color {
        guard average > 0 else { return .green }
        let deviation = abs(frameTime - average)
        let closeTolerance = max(0.75, refreshPeriod * 0.25)
        if deviation <= closeTolerance {
            return .green
        }
        if deviation <= max(3, refreshPeriod) {
            return .yellow
        }
        return .red
    }
}
