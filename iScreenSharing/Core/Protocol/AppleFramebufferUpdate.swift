import Foundation

enum AppleFramebufferUpdate {
    struct Contents: Equatable {
        let displayLayouts: [AppleDisplayLayout]
        let cursorUpdates: [AppleCursorUpdate]
        let vendorKeySymbols: [Set<UInt32>]
        let keyboardInputSources: [AppleKeyboardInputSourceState]
        let deviceInfos: [AppleRemoteDeviceInfo]
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
        var vendorKeySymbols = [Set<UInt32>]()
        var keyboardInputSources = [AppleKeyboardInputSourceState]()
        var deviceInfos = [AppleRemoteDeviceInfo]()
        for event in events(from: message) {
            switch event {
            case .displayLayout(let layout): layouts.append(layout)
            case .cursor(let update): cursors.append(update)
            case .vendorKeySymbols(let symbols): vendorKeySymbols.append(symbols)
            case .keyboardInputSource(let state): keyboardInputSources.append(state)
            case .deviceInfo(let info): deviceInfos.append(info)
            }
        }
        return Contents(
            displayLayouts: layouts,
            cursorUpdates: cursors,
            vendorKeySymbols: vendorKeySymbols,
            keyboardInputSources: keyboardInputSources,
            deviceInfos: deviceInfos
        )
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
            } else if encoding == 1107,
                      let symbols = vendorKeySymbols(
                          from: message.subdata(in: payloadStart..<payloadEnd)
                      ) {
                events.append(.vendorKeySymbols(symbols))
            } else if encoding == 1109,
                      let state = AppleKeyboardInputSourceMessage.state(
                          from: message.subdata(in: payloadStart..<payloadEnd)
                      ) {
                events.append(.keyboardInputSource(state))
            } else if encoding == 1110,
                      let info = deviceInfo(
                          from: message.subdata(in: payloadStart..<payloadEnd)
                      ) {
                events.append(.deviceInfo(info))
            }
            offset = payloadEnd
        }
        return events
    }

    private static func vendorKeySymbols(from payload: Data) -> Set<UInt32>? {
        guard payload.count >= 4,
              (try? payload.uint16BE(at: 0)) == 1,
              let count = try? Int(payload.uint16BE(at: 2)),
              count <= (payload.count - 4) / 4 else { return nil }
        return Set((0..<count).compactMap { try? payload.uint32BE(at: 4 + $0 * 4) })
    }

    private static func deviceInfo(from payload: Data) -> AppleRemoteDeviceInfo? {
        guard payload.count >= 16,
              let version = try? payload.uint16BE(at: 0),
              let flags = try? payload.uint32BE(at: 2),
              let modelLength = try? Int(payload.uint16BE(at: 10)),
              let deviceColorLength = try? Int(payload.uint16BE(at: 12)),
              let enclosureColorLength = try? Int(payload.uint16BE(at: 14)),
              modelLength > 0,
              deviceColorLength > 0,
              enclosureColorLength > 0 else { return nil }

        let stringBytes = modelLength + deviceColorLength + enclosureColorLength
        let requiredSize = 16 + stringBytes + (version >= 2 ? 4 : 0)
        guard requiredSize <= payload.count else { return nil }

        var offset = 16
        guard let modelIdentifier = nulTerminatedString(
            in: payload,
            at: &offset,
            length: modelLength
        ),
        let deviceColor = nulTerminatedString(
            in: payload,
            at: &offset,
            length: deviceColorLength
        ),
        let enclosureColor = nulTerminatedString(
            in: payload,
            at: &offset,
            length: enclosureColorLength
        ),
        !modelIdentifier.isEmpty else { return nil }

        let rgb = UInt32(payload[6])
            | (UInt32(payload[7]) << 8)
            | (UInt32(payload[8]) << 16)
            | (UInt32(payload[9]) << 24)
        let housingColor = version >= 2 ? try? payload.uint32BE(at: offset) : nil
        return AppleRemoteDeviceInfo(
            modelIdentifier: modelIdentifier,
            deviceColor: deviceColor,
            enclosureColor: enclosureColor,
            enclosureRGBColorComponents: rgb == 0 ? nil : rgb,
            housingColor: housingColor.flatMap { $0 == 0 ? nil : $0 },
            flags: flags
        )
    }

    private static func nulTerminatedString(
        in data: Data,
        at offset: inout Int,
        length: Int
    ) -> String? {
        guard length > 0, offset <= data.count - length else { return nil }
        let bytes = data[offset..<(offset + length)]
        offset += length
        guard bytes.last == 0,
              !bytes.dropLast().contains(0) else { return nil }
        return String(data: bytes.dropLast(), encoding: .utf8)
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
        case vendorKeySymbols(Set<UInt32>)
        case keyboardInputSource(AppleKeyboardInputSourceState)
        case deviceInfo(AppleRemoteDeviceInfo)
    }
}
