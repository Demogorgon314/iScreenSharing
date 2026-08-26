import Foundation

struct AppleRekeyReader {
    func read(from session: RFBAuthenticatedSession) async throws -> AppleRekey {
        while true {
            let messageType = try await session.receiveExactly(1)[0]
            switch messageType {
            case 0x14:
                _ = try await session.receiveExactly(7)
            case 0x00:
                if let rekey = try await readFramebufferUpdate(from: session) {
                    return rekey
                }
            default:
                throw AppleRekeyError.unsupportedFramebufferMessage(messageType)
            }
        }
    }

    private func readFramebufferUpdate(
        from session: RFBAuthenticatedSession
    ) async throws -> AppleRekey? {
        let header = try await session.receiveExactly(3)
        let rectangleCount = Int(try header.uint16BE(at: 1))
        for _ in 0..<rectangleCount {
            let rectangle = try await session.receiveExactly(12)
            let encoding = try rectangle.int32BE(at: 8)
            switch encoding {
            case AppleRekey.encoding:
                return try AppleRekey(
                    payload: try await session.receiveExactly(AppleRekey.payloadLength)
                )
            case 1010, 1011:
                let length = try Int(
                    (try await session.receiveExactly(2)).uint16BE(at: 0)
                )
                _ = try await session.receiveExactly(length)
            default:
                throw AppleRekeyError.unsupportedEncoding(encoding)
            }
        }
        return nil
    }
}

