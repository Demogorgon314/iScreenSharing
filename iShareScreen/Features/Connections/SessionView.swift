import SwiftUI

struct SessionView: View {
    let endpoint: ConnectionEndpoint
    @ObservedObject var sessions: SessionManager

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                Image(systemName: "display")
                    .font(.system(size: 44, weight: .thin))
                Text(endpoint.displayName)
                    .font(.title3)
                Text(statusMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
            }
            .foregroundStyle(.white)
        }
        .onDisappear {
            sessions.disconnect(endpoint)
        }
        .navigationTitle(endpoint.displayName)
        .toolbar {
            ToolbarItemGroup {
                Button { } label: { Image(systemName: "rectangle.inset.filled") }
                    .help("Scale to Fit")
                Button { } label: { Image(systemName: "clipboard") }
                    .help("Clipboard")
            }
        }
    }

    private var statusMessage: String {
        if sessions.session(for: endpoint) != nil {
            "Secure connection established. Preparing the remote display…"
        } else {
            "The connection is no longer active."
        }
    }
}
