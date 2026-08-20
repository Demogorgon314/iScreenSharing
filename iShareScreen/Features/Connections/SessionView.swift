import SwiftUI

struct SessionView: View {
    let endpoint: ConnectionEndpoint

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                Image(systemName: "display")
                    .font(.system(size: 44, weight: .thin))
                Text(endpoint.displayName)
                    .font(.title3)
                Text("The host supports Apple Screen Sharing. Authentication and video negotiation are being implemented next.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
            }
            .foregroundStyle(.white)
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
}

