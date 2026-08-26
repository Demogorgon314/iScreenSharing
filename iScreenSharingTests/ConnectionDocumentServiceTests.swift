import XCTest
@testable import iScreenSharing

@MainActor
final class ConnectionDocumentServiceTests: XCTestCase {
    func testResolvesVNCURL() async throws {
        let url = try XCTUnwrap(URL(string: "vnc://192.168.50.239:5901"))
        let resolvedEndpoint = try await ConnectionDocumentService.endpoint(from: url)

        XCTAssertEqual(
            resolvedEndpoint,
            try ConnectionEndpoint("192.168.50.239:5901")
        )
    }

    func testResolvesVNCInternetLocationFile() async throws {
        let endpoint = try ConnectionEndpoint("deepdream.local")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("Deep Dream.vncloc")
        try ConnectionLocationDocument.data(for: endpoint).write(to: location)
        let resolvedEndpoint = try await ConnectionDocumentService.endpoint(from: location)

        XCTAssertEqual(resolvedEndpoint, endpoint)
    }
}
