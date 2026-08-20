import Combine
import Foundation

@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [ConnectionEndpoint: RFBAuthenticatedSession] = [:]

    func install(_ session: RFBAuthenticatedSession) {
        sessions[session.endpoint]?.close()
        sessions[session.endpoint] = session
    }

    func session(for endpoint: ConnectionEndpoint) -> RFBAuthenticatedSession? {
        sessions[endpoint]
    }

    func disconnect(_ endpoint: ConnectionEndpoint) {
        sessions.removeValue(forKey: endpoint)?.close()
    }
}

