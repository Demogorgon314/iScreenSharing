import Darwin
import XCTest
@testable import iScreenSharing

final class TailscaleTCPTransportTests: XCTestCase {
    func testFormatsIPv4AndIPv6DialAddresses() {
        XCTAssertEqual(
            TailscaleTCPTransport.dialAddress(host: "100.64.0.10", port: 5900),
            "100.64.0.10:5900"
        )
        XCTAssertEqual(
            TailscaleTCPTransport.dialAddress(host: "fd7a:115c:a1e0::1", port: 5901),
            "[fd7a:115c:a1e0::1]:5901"
        )
    }

    func testSendsAllBytesThroughConnectedDescriptor() async throws {
        let (transport, peerDescriptor) = try makeTransport()
        defer {
            transport.cancel()
            Darwin.close(peerDescriptor)
        }
        let expected = Data("RFB 003.889\n".utf8)

        try await transport.send(expected)

        var received = Data(count: expected.count)
        let count = received.withUnsafeMutableBytes {
            Darwin.read(peerDescriptor, $0.baseAddress, $0.count)
        }
        XCTAssertEqual(count, expected.count)
        XCTAssertEqual(received, expected)
    }

    func testReceivesExactlyAcrossMultipleWrites() async throws {
        let (transport, peerDescriptor) = try makeTransport()
        defer {
            transport.cancel()
            Darwin.close(peerDescriptor)
        }
        try write(Data([0x01, 0x02]), to: peerDescriptor)
        try write(Data([0x03, 0x04, 0x05]), to: peerDescriptor)

        let received = try await transport.receiveExactly(5)
        XCTAssertEqual(received, Data([0x01, 0x02, 0x03, 0x04, 0x05]))
    }

    func testReportsPeerClosureDuringExactRead() async throws {
        let (transport, peerDescriptor) = try makeTransport()
        try write(Data([0x01]), to: peerDescriptor)
        Darwin.close(peerDescriptor)

        do {
            _ = try await transport.receiveExactly(2)
            XCTFail("Expected the short stream to close")
        } catch RFBNetworkError.connectionClosed {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        transport.cancel()
    }

    private func makeTransport() throws -> (TailscaleTCPTransport, Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (TailscaleTCPTransport(connectedFileDescriptor: descriptors[0]), descriptors[1])
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        let count = data.withUnsafeBytes {
            Darwin.write(descriptor, $0.baseAddress, $0.count)
        }
        guard count == data.count else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
