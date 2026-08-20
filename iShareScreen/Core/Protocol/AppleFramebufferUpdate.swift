import Foundation

enum AppleFramebufferUpdate {
    struct Contents: Equatable {
        let displayLayouts: [AppleDisplayLayout]
        let cursorUpdates: [AppleCursorUpdate]
    }

    private static let lengthPrefixedEncodings: Set<Int32> = [
        1010, 1011, 1107, 1109, 1110,
        0x3ea, 0x3f2, 0x3f3, 0x453, 0x455, 0x456,
    ]

    static func displayLayouts(from message: Data) -> [AppleDisplayLayout] {
        contents(from: message).displayLayouts
    }

    static func cursorUpdates(from message: Data) -> [AppleCursorUpdate] {
        contents(from: message).cursorUpdates
    }

    static func contents(from message: Data) -> Contents {
        var layouts = [AppleDisplayLayout]()
        var cursors = [AppleCursorUpdate]()
        for event in events(from: message) {
            switch event {
            case .displayLayout(let layout): layouts.append(layout)
            case .cursor(let update): cursors.append(update)
            }
        }
        return Contents(displayLayouts: layouts, cursorUpdates: cursors)
    }

    private static func events(from message: Data) -> [Event] {
        guard message.count >= 4, message[0] == 0,
              let rectangleCount = try? message.uint16BE(at: 2) else { return [] }

        var events: [Event] = []
        var offset = 4
        for _ in 0..<rectangleCount {
            guard offset <= message.count - 12,
                  let hotspotX = try? message.uint16BE(at: offset),
                  let hotspotY = try? message.uint16BE(at: offset + 2),
                  let width = try? message.uint16BE(at: offset + 4),
                  let height = try? message.uint16BE(at: offset + 6),
                  let encoding = try? message.int32BE(at: offset + 8) else { return events }
            offset += 12

            if encoding == 0x450 {
                guard offset <= message.count - 8,
                      let cacheID = try? message.uint32BE(at: offset),
                      let compressedLength = try? message.uint32BE(at: offset + 4),
                      Int(compressedLength) <= message.count - offset - 8 else { return events }
                let payloadStart = offset + 8
                let payloadEnd = payloadStart + Int(compressedLength)
                if compressedLength == 0 {
                    events.append(.cursor(.select(id: cacheID)))
                } else if let image = cursorImage(
                    width: Int(width),
                    height: Int(height),
                    hotspotX: Int(hotspotX),
                    hotspotY: Int(hotspotY),
                    compressed: message.subdata(in: payloadStart..<payloadEnd)
                ) {
                    events.append(.cursor(.store(id: cacheID, image: image)))
                }
                offset = payloadEnd
                continue
            }

            guard lengthPrefixedEncodings.contains(encoding) || encoding == 0x451,
                  offset <= message.count - 2,
                  let payloadLength = try? message.uint16BE(at: offset),
                  Int(payloadLength) <= message.count - offset - 2 else { return events }
            let payloadStart = offset + 2
            let payloadEnd = payloadStart + Int(payloadLength)
            if encoding == 0x451,
               let layout = AppleDisplayConfiguration.layout(
                   from: message.subdata(in: payloadStart..<payloadEnd)
               ) {
                events.append(.displayLayout(layout))
            }
            offset = payloadEnd
        }
        return events
    }

    private static func cursorImage(
        width: Int,
        height: Int,
        hotspotX: Int,
        hotspotY: Int,
        compressed: Data
    ) -> AppleCursorImage? {
        guard width > 0, height > 0,
              hotspotX < width, hotspotY < height else { return nil }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow else { return nil }
        let (expectedSize, sizeOverflow) = pixelCount.multipliedReportingOverflow(by: 5)
        guard !sizeOverflow,
              let raw = try? ZlibCodec.decompressSyncFlush(compressed, expectedSize: expectedSize),
              raw.count == expectedSize else { return nil }

        let pixelBytes = pixelCount * 4
        var rgba = Data(repeating: 0, count: pixelBytes)
        for pixel in 0..<pixelCount {
            let offset = pixel * 4
            rgba[offset] = raw[offset + 2]
            rgba[offset + 1] = raw[offset + 1]
            rgba[offset + 2] = raw[offset]
            rgba[offset + 3] = raw[pixelBytes + pixel]
        }
        return AppleCursorImage(
            width: width,
            height: height,
            hotspotX: hotspotX,
            hotspotY: hotspotY,
            rgba: rgba
        )
    }

    private enum Event {
        case displayLayout(AppleDisplayLayout)
        case cursor(AppleCursorUpdate)
    }
}
