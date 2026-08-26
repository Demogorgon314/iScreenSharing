import Foundation

protocol RFBTransport: AnyObject, Sendable {
    func start(timeout: Duration) async throws
    func send(_ data: Data) async throws
    func receiveExactly(_ length: Int) async throws -> Data
    func cancel()
}

extension RFBTransport {
    func start() async throws {
        try await start(timeout: .seconds(15))
    }
}
