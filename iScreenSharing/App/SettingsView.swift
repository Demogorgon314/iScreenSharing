import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var tailscale: TailscaleModel
    @ObservedObject var sessions: SessionManager

    var body: some View {
        TabView {
            DisplaySettingsView()
                .tabItem {
                    Label("Display", systemImage: "display")
                }

            TailscaleSettingsView(tailscale: tailscale, sessions: sessions)
                .tabItem {
                    Label("Tailscale", systemImage: "circle.grid.3x3.fill")
                }
        }
        .frame(width: 560, height: 330)
    }
}

private struct DisplaySettingsView: View {
    private enum DisplayScale: Hashable {
        case scaleToFit
        case actualSize
    }

    @AppStorage(SessionFeaturePreferences.fixedDisplayScaleKey)
    private var fixedDisplayScale = -1.0
    @AppStorage(SessionFeaturePreferences.usesDynamicResolutionKey)
    private var usesDynamicResolution = true
    @AppStorage(SessionFeaturePreferences.synchronizesVideoPresentationKey)
    private var synchronizesVideoPresentation = true
    @AppStorage(SessionFeaturePreferences.showsVideoPerformanceOverlayKey)
    private var showsVideoPerformanceOverlay = false
    @AppStorage(SessionFeaturePreferences.videoPerformanceLevelKey)
    private var videoPerformanceLevel = VideoPerformanceLevel.compact
    @AppStorage(SessionFeaturePreferences.showsMetalPerformanceHUDKey)
    private var showsMetalPerformanceHUD = false

    var body: some View {
        Form {
            Section("When viewing a computer with a larger screen") {
                Picker("Display size", selection: displayScale) {
                    Text("Scale to fit available space").tag(DisplayScale.scaleToFit)
                    Text("Show at actual size").tag(DisplayScale.actualSize)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            }

            Section("Video") {
                Toggle("Adapt the remote resolution to the window", isOn: $usesDynamicResolution)
                Toggle("Synchronize video presentation", isOn: $synchronizesVideoPresentation)
            }

            Section {
                DisclosureGroup("Diagnostics") {
                    Toggle("Show video performance", isOn: $showsVideoPerformanceOverlay)
                    Picker("Metrics level", selection: $videoPerformanceLevel) {
                        ForEach(VideoPerformanceLevel.allCases) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    .disabled(!showsVideoPerformanceOverlay)
                    Toggle("Show Metal performance HUD", isOn: $showsMetalPerformanceHUD)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var displayScale: Binding<DisplayScale> {
        Binding(
            get: { fixedDisplayScale < 0 ? .scaleToFit : .actualSize },
            set: { fixedDisplayScale = $0 == .scaleToFit ? -1 : 1 }
        )
    }
}

private struct TailscaleSettingsView: View {
    @ObservedObject var tailscale: TailscaleModel
    @ObservedObject var sessions: SessionManager
    @State private var shouldOpenLogin = false
    @State private var showsLogoutConfirmation = false

    var body: some View {
        Group {
            switch tailscale.state {
            case .starting:
                statusView("Starting Tailscale…")
            case .needsLogin:
                loginView
            case .needsMachineApproval:
                unavailableView(
                    "Device Approval Required",
                    systemImage: "person.badge.clock",
                    description: "Approve this embedded iScreenSharing node in your Tailscale admin console.",
                    actionTitle: "Open Approval Page",
                    action: openLogin
                )
            case .running:
                accountView
            case .stopped:
                unavailableView(
                    "Tailscale Is Stopped",
                    systemImage: "pause.circle",
                    description: "Restart the embedded node to access your tailnet.",
                    actionTitle: "Restart",
                    action: tailscale.retry
                )
            case .failed(let message):
                unavailableView(
                    "Can’t Start Tailscale",
                    systemImage: "exclamationmark.triangle",
                    description: message,
                    actionTitle: "Try Again",
                    action: tailscale.retry
                )
            }
        }
        .task {
            tailscale.start()
        }
        .onChange(of: tailscale.authenticationURL) { _, url in
            guard shouldOpenLogin, let url else { return }
            shouldOpenLogin = false
            NSWorkspace.shared.open(url)
        }
        .alert("Log Out of Tailscale?", isPresented: $showsLogoutConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Log Out", role: .destructive) {
                sessions.disconnectTailscaleSessions()
                Task { await tailscale.logout() }
            }
        } message: {
            Text(logoutConfirmationMessage)
        }
    }

    private var accountView: some View {
        Form {
            Section("Account") {
                LabeledContent("Status") {
                    Label("Connected", systemImage: "circle.fill")
                        .foregroundStyle(.green)
                }
                LabeledContent("Available computers", value: "\(tailscale.peers.count)")
            }

            Section {
                HStack {
                    Spacer()
                    if tailscale.isLoggingOut {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Log Out…") {
                        showsLogoutConfirmation = true
                    }
                    .disabled(tailscale.isLoggingOut)
                }

                if let message = tailscale.logoutErrorMessage {
                    Text(message)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("iScreenSharing uses its own embedded Tailscale node. Logging out here does not affect the Tailscale app on this Mac.")
            }
        }
        .formStyle(.grouped)
    }

    private var loginView: some View {
        VStack(spacing: 18) {
            Image(systemName: "circle.grid.3x3.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text("Access Your Tailscale Computers")
                    .font(.title2.bold())
                Text("Link your account to discover and connect to Macs on your tailnet.")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            Button {
                openLogin()
            } label: {
                HStack(spacing: 8) {
                    if tailscale.isLinkingAccount {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(tailscale.isLinkingAccount ? "Preparing Login…" : "Link Account")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(tailscale.isLinkingAccount)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusView(_ title: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailableView(
        _ title: String,
        systemImage: String,
        description: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        } actions: {
            Button(actionTitle, action: action)
        }
    }

    private func openLogin() {
        if let url = tailscale.authenticationURL {
            NSWorkspace.shared.open(url)
        } else {
            shouldOpenLogin = true
        }
        tailscale.linkAccount()
    }

    private var logoutConfirmationMessage: String {
        let base = "Tailscale computers will no longer appear in iScreenSharing. Saved connections and passwords will not be removed."
        let count = sessions.tailscaleSessionCount
        guard count > 0 else { return base }
        let sessions = count == 1 ? "session" : "sessions"
        return "\(base) \(count) active Tailscale \(sessions) will be disconnected."
    }
}
