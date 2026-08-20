import Foundation

enum AppleFramebufferUpdate {
    private static let lengthPrefixedEncodings: Set<Int32> = [
        1010, 1011, 1107, 1109, 1110,
        0x3ea, 0x3f2, 0x3f3, 0x453, 0x455, 0x456,
    ]

    static func displayLayouts(from message: Data) -> [AppleDisplayLayout] {
        guard message.count >= 4, message[0] == 0,
              let rectangleCount = try? message.uint16BE(at: 2) else { return [] }

        var layouts: [AppleDisplayLayout] = []
        var offset = 4
        for _ in 0..<rectangleCount {
            guard offset <= message.count - 12,
                  let encoding = try? message.int32BE(at: offset + 8) else { return layouts }
            offset += 12

            guard lengthPrefixedEncodings.contains(encoding) || encoding == 0x451,
                  offset <= message.count - 2,
                  let payloadLength = try? message.uint16BE(at: offset),
                  Int(payloadLength) <= message.count - offset - 2 else { return layouts }
            let payloadStart = offset + 2
            let payloadEnd = payloadStart + Int(payloadLength)
            if encoding == 0x451,
               let layout = AppleDisplayConfiguration.layout(
                   from: message.subdata(in: payloadStart..<payloadEnd)
               ) {
                layouts.append(layout)
            }
            offset = payloadEnd
        }
        return layouts
    }
}
