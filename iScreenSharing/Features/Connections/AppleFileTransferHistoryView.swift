import SwiftUI

struct FileTransferToolbarButton: View {
    @ObservedObject var history: AppleFileTransferHistory
    let fileTransfer: AppleFileTransferService
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Label("File Transfers", systemImage: "arrow.up.arrow.down.circle")
        }
        .help("File Transfers")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AppleFileTransferHistoryView(
                history: history,
                fileTransfer: fileTransfer
            )
        }
    }
}

private struct AppleFileTransferHistoryView: View {
    @ObservedObject var history: AppleFileTransferHistory
    let fileTransfer: AppleFileTransferService

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
                            AppleFileTransferRow(
                                entry: entry,
                                setPaused: { paused in
                                    Task {
                                        await fileTransfer.setTransferPaused(
                                            historyID: entry.id,
                                            paused: paused
                                        )
                                    }
                                },
                                cancel: {
                                    Task {
                                        await fileTransfer.cancelTransfer(
                                            historyID: entry.id
                                        )
                                    }
                                }
                            )
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
    let setPaused: (Bool) -> Void
    let cancel: () -> Void

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
                Text(entry.direction == .toRemote
                    ? "To \(entry.remoteName)"
                    : "From \(entry.remoteName)")
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

            if entry.state.isTerminal {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL])
                } label: {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show in Finder")
            } else {
                HStack(spacing: 8) {
                    if canPauseOrResume {
                        Button { setPaused(entry.state != .paused) } label: {
                            Image(systemName: entry.state == .paused
                                ? "play.circle.fill"
                                : "pause.circle.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(entry.state == .paused
                            ? "Resume Transfer"
                            : "Pause Transfer")
                    }

                    Button(action: cancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Cancel Transfer")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusText: String {
        let text = switch entry.state {
        case .waitingForRemote: "Waiting for the remote Mac…"
        case .sending: "Sending…"
        case .receiving: "Receiving…"
        case .paused: "Paused"
        case .completing: "Finishing…"
        case .sent: "Sent"
        case .received: "Received"
        case .failed(let message): "Failed: \(message)"
        case .cancelled: "Cancelled"
        }
        guard entry.state == .sending,
              let rate = entry.transferRateBytesPerSecond,
              rate > 0 else { return text }
        let byteCount = Int64(min(rate.rounded(), Double(Int64.max)))
        let formattedRate = ByteCountFormatter.string(
            fromByteCount: byteCount,
            countStyle: .file
        )
        return "\(text) · \(formattedRate)/s"
    }

    private var statusColor: Color {
        if case .failed = entry.state { return .red }
        return .secondary
    }

    private var canPauseOrResume: Bool {
        switch entry.state {
        case .sending, .receiving, .paused: true
        case .waitingForRemote, .completing, .sent, .received, .failed, .cancelled: false
        }
    }
}
