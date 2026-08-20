import SwiftUI

struct SessionView: View {
    let endpoint: ConnectionEndpoint
    @ObservedObject var sessions: SessionManager
    @State private var displayScale = AppleVideoDisplayScale()

    var body: some View {
        Group {
            if let session = sessions.session(for: endpoint), let stream = session.videoStream {
                ActiveVideoSessionView(
                    stream: stream,
                    input: session.inputController,
                    displayScale: displayScale
                )
            } else {
                unavailableContent
            }
        }
        .onDisappear {
            sessions.disconnect(endpoint)
        }
        .navigationTitle(endpoint.displayName)
        .focusedSceneValue(\.sessionDisplayScale, $displayScale)
        .toolbar {
            ToolbarItemGroup {
                Button { displayScale.toggleScaling() } label: {
                    Image(systemName: displayScale.scalesToFit ? "rectangle.inset.filled" : "rectangle")
                }
                    .help(displayScale.scalesToFit ? "Turn Scaling Off" : "Turn Scaling On")
                Button { sendClipboard() } label: { Image(systemName: "clipboard") }
                    .help("Send Clipboard to Remote Mac")
                if let audio = sessions.session(for: endpoint)?.audioStream {
                    AudioMuteButton(audio: audio)
                }
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

    private func sendClipboard() {
        guard let session = sessions.session(for: endpoint),
              let input = session.inputController,
              let text = session.clipboardService?.localText() else { return }
        Task { try? await input.sendClipboard(text) }
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
    let displayScale: AppleVideoDisplayScale

    var body: some View {
        ZStack {
            Color.black
            RemoteVideoCanvasView(
                canvas: stream.canvas,
                frames: stream.frames,
                input: input,
                displayScale: displayScale
            )
            if stream.state != .streaming {
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

    private var statusMessage: String {
        switch stream.state {
        case .preparing: "Preparing the remote display…"
        case .streaming: ""
        case .failed(let message): message
        case .stopped: "The connection is no longer active."
        }
    }
}
