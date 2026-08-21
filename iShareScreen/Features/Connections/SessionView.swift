import SwiftUI

struct SessionView: View {
    let endpoint: ConnectionEndpoint
    @ObservedObject var sessions: SessionManager
    @State private var displayScale = AppleVideoDisplayScale()
    @State private var isObserving = false
    @State private var isChangingMode = false
    @State private var modeError: String?
    @State private var viewportSize = CGSize.zero
    @StateObject private var dynamicResolution = AppleDynamicResolutionModel()

    var body: some View {
        Group {
            if let session = sessions.session(for: endpoint), let stream = session.videoStream {
                ActiveVideoSessionView(
                    stream: stream,
                    input: isObserving ? nil : session.inputController,
                    cursors: session.cursorStore,
                    displayScale: displayScale,
                    onViewportChange: viewportChanged
                )
            } else {
                unavailableContent
            }
        }
        .onDisappear {
            dynamicResolution.cancel()
            sessions.disconnect(endpoint)
        }
        .navigationTitle(endpoint.displayName)
        .focusedSceneValue(\.sessionEndpoint, endpoint)
        .focusedSceneValue(\.sessionDisplayScale, $displayScale)
        .focusedSceneValue(
            \.dynamicResolutionActions,
            DynamicResolutionActions(
                isEnabled: dynamicResolution.isEnabled,
                canToggle: sessions.session(for: endpoint)?.dynamicResolutionController != nil,
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
                Button { displayScale.toggleScaling() } label: {
                    Image(systemName: displayScale.scalesToFit ? "rectangle.inset.filled" : "rectangle")
                }
                    .help(displayScale.scalesToFit ? "Turn Scaling Off" : "Turn Scaling On")
                Button { sendClipboard() } label: { Image(systemName: "clipboard") }
                    .help("Send Clipboard to Remote Mac")
                    .disabled(isObserving)
                Button { toggleObservationMode() } label: {
                    Image(systemName: isObserving ? "eye.fill" : "cursorarrow.rays")
                }
                .help(isObserving ? "Switch to Control Mode" : "Switch to Observe Mode")
                .disabled(isChangingMode || sessions.session(for: endpoint) == nil)
                if let audio = sessions.session(for: endpoint)?.audioStream {
                    AudioMuteButton(audio: audio)
                }
            }
        }
        .alert("Unable to Change Mode", isPresented: modeErrorIsPresented) {
            Button("OK") { modeError = nil }
        } message: {
            Text(modeError ?? "The Screen Sharing mode could not be changed.")
        }
        .alert("Unable to Change Resolution", isPresented: resolutionErrorIsPresented) {
            Button("OK") { dynamicResolution.clearError() }
        } message: {
            Text(dynamicResolution.errorMessage ?? "The remote display resolution could not be changed.")
        }
        .onChange(of: dynamicResolution.isEnabled) { _, enabled in
            if enabled { scheduleDynamicResolution() } else { dynamicResolution.cancel() }
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
        guard let session = sessions.session(for: endpoint),
              let input = session.inputController,
              let text = session.clipboardService?.localText() else { return }
        Task { try? await input.sendClipboard(text) }
    }

    private var modeErrorIsPresented: Binding<Bool> {
        Binding(
            get: { modeError != nil },
            set: { if !$0 { modeError = nil } }
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
        scheduleDynamicResolution()
    }

    private func scheduleDynamicResolution() {
        guard let controller = sessions.session(for: endpoint)?.dynamicResolutionController else { return }
        dynamicResolution.schedule(viewport: viewportSize, controller: controller)
    }

    private func toggleObservationMode() {
        guard !isChangingMode, let session = sessions.session(for: endpoint) else { return }
        let newValue = !isObserving
        isChangingMode = true
        Task {
            do {
                try await session.sendEncrypted(AppleRFBMessages.controlMode(observing: newValue))
                await MainActor.run {
                    isObserving = newValue
                    isChangingMode = false
                }
            } catch {
                await MainActor.run {
                    modeError = error.localizedDescription
                    isChangingMode = false
                }
            }
        }
    }
}

private struct AudioMuteButton: View {
    @ObservedObject var audio: AppleAudioStream

    var body: some View {
        Button { audio.toggleMute() } label: {
            Image(systemName: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        .help(audio.isMuted ? "Unmute" : "Mute")
    }
}

private struct ActiveVideoSessionView: View {
    @ObservedObject var stream: AppleVideoStream
    let input: AppleInputController?
    let cursors: AppleCursorStore?
    let displayScale: AppleVideoDisplayScale
    let onViewportChange: (CGSize) -> Void

    var body: some View {
        ZStack {
            Color.black
            RemoteVideoCanvasView(
                canvas: stream.canvas,
                frames: stream.frames,
                input: input,
                cursors: cursors,
                displayScale: displayScale
            )
            .id(stream.canvas)
            if stream.state != .streaming {
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

    private var statusMessage: String {
        switch stream.state {
        case .preparing: "Preparing the remote display…"
        case .streaming: ""
        case .failed(let message): message
        case .stopped: "The connection is no longer active."
        }
    }
}
