import SwiftUI

struct SessionView: View {
    let endpoint: ConnectionEndpoint
    @ObservedObject var sessions: SessionManager
    @State private var scalesToFit = true

    var body: some View {
        Group {
            if let session = sessions.session(for: endpoint), let stream = session.videoStream {
                ActiveVideoSessionView(
                    stream: stream,
                    input: session.inputController,
                    scalesToFit: scalesToFit
                )
            } else {
                unavailableContent
            }
        }
        .onDisappear {
            sessions.disconnect(endpoint)
        }
        .navigationTitle(endpoint.displayName)
        .toolbar {
            ToolbarItemGroup {
                Button { scalesToFit.toggle() } label: {
                    Image(systemName: scalesToFit ? "rectangle.inset.filled" : "rectangle")
                }
                    .help("Scale to Fit")
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
    let scalesToFit: Bool

    var body: some View {
        ZStack {
            Color.black
            RemoteVideoCanvasView(
                canvas: stream.canvas,
                frames: stream.frames,
                input: input,
                scalesToFit: scalesToFit
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
