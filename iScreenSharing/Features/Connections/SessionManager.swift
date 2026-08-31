import Combine
import Foundation

@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [ConnectionEndpoint: RFBAuthenticatedSession] = [:]

    func install(_ session: RFBAuthenticatedSession) {
        guard sessions[session.endpoint] !== session else { return }
        let replacedSession = sessions[session.endpoint]
        sessions[session.endpoint] = session
        session.setTerminationHandler { [weak self, weak session] in
            Task { @MainActor [weak self, weak session] in
                guard let self, let session,
                      self.sessions[session.endpoint] === session else { return }
                self.sessions.removeValue(forKey: session.endpoint)
            }
        }
        replacedSession?.close()
    }

    func session(for endpoint: ConnectionEndpoint) -> RFBAuthenticatedSession? {
        sessions[endpoint]
    }

    func disconnect(_ endpoint: ConnectionEndpoint) {
        sessions.removeValue(forKey: endpoint)?.close()
    }

    var tailscaleSessionCount: Int {
        sessions.keys.count { $0.route == .tailscale }
    }

    func disconnectTailscaleSessions() {
        let endpoints = sessions.keys.filter { $0.route == .tailscale }
        for endpoint in endpoints {
            disconnect(endpoint)
        }
    }
}
