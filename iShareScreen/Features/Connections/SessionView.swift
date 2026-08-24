import SwiftUI

struct SessionView: View {
    let endpoint: ConnectionEndpoint
    @ObservedObject var sessions: SessionManager
    @ObservedObject var displayLayout: AppleDisplayLayoutModel
    @ObservedObject var dynamicResolution: AppleDynamicResolutionModel
    @ObservedObject var controlState: AppleSessionControlState
    let displayIndex: Int
    let disconnectsSessionOnDisappear: Bool
    @State private var viewportSize = CGSize.zero
    @State private var sessionWindowIdentifier = UUID()
    @AppStorage(SessionFeaturePreferences.fixedDisplayScaleKey)
    private var storedFixedDisplayScale = -1.0
    @AppStorage(SessionFeaturePreferences.synchronizesVideoPresentationKey)
    private var synchronizesVideoPresentation = true
    @AppStorage(SessionFeaturePreferences.showsVideoPerformanceOverlayKey)
    private var showsVideoPerformanceOverlay = false
    @AppStorage(SessionFeaturePreferences.showsMetalPerformanceHUDKey)
    private var showsMetalPerformanceHUD = false
    let videoRenderer: AppleVideoRenderer
    private let viewportStore = SessionViewportStore()

    private var isObserving: Bool { controlState.isObserving }
    private var isChangingMode: Bool { controlState.isChangingMode }

    var body: some View {
        Group {
            if let session = sessions.session(for: endpoint),
               let stream = session.videoStream(for: displayIndex) {
                let usesIndependentVideoStreams = session.videoStreams.count > 1
                ActiveVideoSessionView(
                    renderer: videoRenderer,
                    stream: stream,
                    input: isObserving ? nil : session.inputController,
                    cursors: session.cursorStore,
                    displayScale: displayScale,
                    synchronizesPresentation: synchronizesVideoPresentation,
                    showsPerformanceOverlay: showsVideoPerformanceOverlay,
                    showsMetalPerformanceHUD: showsMetalPerformanceHUD,
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
        .focusedSceneValue(\.sessionEndpoint, endpoint)
        .focusedSceneValue(
            \.remoteSystemActions,
            remoteSystemActions
        )
        .focusedSceneValue(\.sessionToolbarActions, sessionToolbarActions)
        .focusedSceneValue(\.sessionDisplayScale, displayScaleBinding)
        .focusedSceneValue(\.synchronizesVideoPresentation, $synchronizesVideoPresentation)
        .focusedSceneValue(
            \.dynamicResolutionActions,
            DynamicResolutionActions(
                isEnabled: dynamicResolution.isEnabled,
                canToggle: canUseDynamicResolution,
                toggle: { dynamicResolution.isEnabled.toggle() }
            )
        )
        .focusedSceneValue(
            \.sessionModeActions,
            SessionModeActions(
                isObserving: isObserving,
                canToggle: sessions.session(for: endpoint) != nil && !isChangingMode,
                toggle: toggleObservationMode
            )
        )
        .toolbar {
            ToolbarItemGroup {
                Button { toggleDisplayScaling() } label: {
                    Label(
                        displayScale.scalesToFit ? "Turn Scaling Off" : "Turn Scaling On",
                        systemImage: displayScale.scalesToFit ? "rectangle.inset.filled" : "rectangle"
                    )
                }
                    .help(displayScale.scalesToFit ? "Turn Scaling Off" : "Turn Scaling On")
                Button { sendClipboard() } label: {
                    Label("Send Clipboard", systemImage: "clipboard")
                }
                    .help("Send Clipboard to Remote Mac")
                    .disabled(isObserving || isChangingMode)
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
                Button { toggleObservationMode() } label: {
                    Label(
                        isObserving ? "Control" : "Observe",
                        systemImage: isObserving ? "eye.fill" : "cursorarrow.rays"
                    )
                }
                .help(isObserving ? "Switch to Control Mode" : "Switch to Observe Mode")
                .disabled(isChangingMode || sessions.session(for: endpoint) == nil)
                Toggle(isOn: $dynamicResolution.isEnabled) {
                    Label("Dynamic Resolution", systemImage: "display")
                }
                .toggleStyle(.button)
                .help("Dynamic Resolution")
                .disabled(!canUseDynamicResolution)
                Toggle(isOn: $synchronizesVideoPresentation) {
                    Label("Synchronize Video", systemImage: "arrow.triangle.2.circlepath")
                }
                .toggleStyle(.button)
                .help("Synchronize Video")
                Toggle(isOn: $showsVideoPerformanceOverlay) {
                    Label("Video Performance", systemImage: "chart.xyaxis.line")
                }
                .toggleStyle(.button)
                .help("Video Performance")
                Toggle(isOn: $showsMetalPerformanceHUD) {
                    Label("Metal Performance HUD", systemImage: "gauge.with.needle")
                }
                .toggleStyle(.button)
                .help("Metal Performance HUD")
                if let audio = sessions.session(for: endpoint)?.audioStream {
                    AudioMuteButton(audio: audio)
                }
            }
        }
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
            if enabled { scheduleDynamicResolution() } else { dynamicResolution.cancel() }
        }
        .onChange(of: displayLayout.layout) { _, _ in
            if canUseDynamicResolution { scheduleDynamicResolution() } else { dynamicResolution.cancel() }
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

    private func sendClipboard() {
        guard !isObserving,
              !isChangingMode,
              let session = sessions.session(for: endpoint),
              let input = session.inputController,
              let archive = session.clipboardService?.localArchive() else { return }
        Task { try? await input.sendClipboard(archive) }
    }

    private var displayScale: AppleVideoDisplayScale {
        AppleVideoDisplayScale(
            fixedScale: storedFixedDisplayScale >= 0
                ? CGFloat(storedFixedDisplayScale)
                : nil
        )
    }

    private var displayScaleBinding: Binding<AppleVideoDisplayScale> {
        Binding(
            get: { displayScale },
            set: { scale in
                storedFixedDisplayScale = scale.fixedScale.map(Double.init) ?? -1
            }
        )
    }

    private func toggleDisplayScaling() {
        var scale = displayScale
        scale.toggleScaling()
        displayScaleBinding.wrappedValue = scale
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
        scheduleDynamicResolution()
    }

    private func scheduleDynamicResolution() {
        guard canUseDynamicResolution,
              let session = sessions.session(for: endpoint),
              session.videoStream(for: displayIndex)?.state == .streaming,
              let controller = session.dynamicResolutionController else { return }
        dynamicResolution.schedule(
            displayIndex: displayIndex,
            viewport: viewportSize,
            canvas: session.videoStream(for: displayIndex)?.canvas,
            layout: displayLayout.layout,
            controller: controller
        )
    }

    private var canUseDynamicResolution: Bool {
        displayLayout.supportsDynamicResolution
            && sessions.session(for: endpoint)?.dynamicResolutionController != nil
    }

    private func toggleObservationMode() {
        controlState.toggleMode()
    }

    private var remoteSystemActions: RemoteSystemActions? {
        guard let session = sessions.session(for: endpoint),
              session.inputController != nil,
              let capabilities = session.remoteSystemCapabilities else { return nil }
        return RemoteSystemActions(
            canPerform: { command in
                !isObserving && !isChangingMode && capabilities.supports(command)
            },
            perform: performRemoteSystemCommand
        )
    }

    private var sessionToolbarActions: SessionToolbarActions? {
        guard let session = sessions.session(for: endpoint) else { return nil }
        let keyboardInputSource = session.keyboardInputSourceService.map { service in
            SessionToggleActions(
                isEnabled: !isObserving && !isChangingMode && service.isSupported,
                isOn: Binding(
                    get: { service.isSharingEnabled },
                    set: { service.setSharingEnabled($0) }
                )
            )
        }
        let audioMuted = session.audioStream.map { audio in
            SessionToggleActions(
                isEnabled: true,
                isOn: Binding(
                    get: { audio.isMuted },
                    set: { isMuted in
                        guard audio.isMuted != isMuted else { return }
                        audio.toggleMute()
                    }
                )
            )
        }
        return SessionToolbarActions(
            canSendClipboard: !isObserving
                && !isChangingMode
                && session.inputController != nil
                && session.clipboardService != nil,
            sendClipboard: sendClipboard,
            keyboardInputSource: keyboardInputSource,
            showsVideoPerformance: $showsVideoPerformanceOverlay,
            showsMetalPerformanceHUD: $showsMetalPerformanceHUD,
            audioMuted: audioMuted
        )
    }

    private func performRemoteSystemCommand(_ command: AppleRemoteSystemCommand) {
        guard !isObserving,
              !isChangingMode,
              let session = sessions.session(for: endpoint),
              session.remoteSystemCapabilities?.supports(command) == true,
              let input = session.inputController else { return }
        Task { await input.perform(command) }
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
    let cursors: AppleCursorStore?
    let displayScale: AppleVideoDisplayScale
    let synchronizesPresentation: Bool
    let showsPerformanceOverlay: Bool
    let showsMetalPerformanceHUD: Bool
    let sourceRect: CGRect?
    let inputMapping: AppleDisplayInputMapping?
    let inputCoordinatesAreDisplayLocal: Bool
    let inputDisplayID: UInt32?
    let onWindowKeyChange: (Bool) -> Void
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
                cursors: cursors,
                displayScale: displayScale,
                synchronizesPresentation: synchronizesPresentation,
                showsDeveloperHUD: showsMetalPerformanceHUD,
                sourceRect: sourceRect,
                inputMapping: inputMapping,
                inputCoordinatesAreDisplayLocal: inputCoordinatesAreDisplayLocal,
                inputDisplayID: inputDisplayID,
                onWindowKeyChange: onWindowKeyChange
            )
            if showsPerformanceOverlay {
                AppleVideoPerformanceOverlay(performance: stream.performance)
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

    var body: some View {
        let stats = performance.snapshot
        VStack(alignment: .leading, spacing: 3) {
            Text(String(
                format: "Network  %.1f Mb/s  %.0f pkt/s",
                stats.networkMegabitsPerSecond,
                stats.networkPacketsPerSecond
            ))
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
