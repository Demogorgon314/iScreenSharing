import SwiftUI

struct FileTransferToolbarButton: View {
    @ObservedObject var history: AppleFileTransferHistory
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Label("File Transfers", systemImage: "arrow.up.arrow.down.circle")
        }
        .help("File Transfers")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AppleFileTransferHistoryView(history: history)
        }
    }
}

private struct AppleFileTransferHistoryView: View {
    @ObservedObject var history: AppleFileTransferHistory

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("File Transfers")
                    .font(.headline)
                HStack {
                    Spacer()
                    Button("Clear") { history.clearCompleted() }
                        .disabled(!history.canClear)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if history.entries.isEmpty {
                ContentUnavailableView(
                    "No File Transfers",
                    systemImage: "arrow.up.arrow.down.circle",
                    description: Text("Drag a file onto the remote display to send it.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(history.entries) { entry in
                            AppleFileTransferRow(entry: entry)
                            if entry.id != history.entries.last?.id {
                                Divider().padding(.leading, 72)
                            }
                        }
                    }
                }
            }
        }
        .frame(
            width: 440,
            height: min(440, max(180, CGFloat(history.entries.count) * 94 + 54))
        )
    }
}

private struct AppleFileTransferRow: View {
    let entry: AppleFileTransferEntry

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.fileURL.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.fileURL.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("To \(entry.remoteName)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(statusText)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                if !entry.state.isTerminal, entry.state != .waitingForRemote {
                    ProgressView(value: entry.progress)
                        .progressViewStyle(.linear)
                }
            }

            Spacer(minLength: 4)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL])
            } label: {
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Show in Finder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusText: String {
        switch entry.state {
        case .waitingForRemote: "Waiting for the remote Mac…"
        case .sending: "Sending…"
        case .completing: "Finishing…"
        case .sent: "Sent"
        case .failed(let message): "Failed: \(message)"
        case .cancelled: "Cancelled"
        }
    }

    private var statusColor: Color {
        if case .failed = entry.state { return .red }
        return .secondary
    }
}
