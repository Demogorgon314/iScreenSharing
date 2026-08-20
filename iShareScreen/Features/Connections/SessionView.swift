import SwiftUI

struct SessionView: View {
    let endpoint: ConnectionEndpoint
    @ObservedObject var sessions: SessionManager
    @State private var scalesToFit = true

    var body: some View {
        Group {
            if let stream = sessions.session(for: endpoint)?.videoStream {
                ActiveVideoSessionView(stream: stream, scalesToFit: scalesToFit)
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
                Button { } label: { Image(systemName: "clipboard") }
                    .help("Clipboard")
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
}

private struct ActiveVideoSessionView: View {
    @ObservedObject var stream: AppleVideoStream
    let scalesToFit: Bool

    var body: some View {
        ZStack {
            Color.black
            RemoteVideoCanvasView(
                canvas: stream.canvas,
                frames: stream.frames,
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
