import Foundation

struct AppleMediaKeys: Equatable, Sendable {
    static let blobLength = 46

    let audioViewer: Data
    let audioServer: Data
    let videoViewer: Data
    let videoServer: Data
    let secondaryVideoViewer: Data?
    let secondaryVideoServer: Data?

    init(
        audioViewer: Data,
        audioServer: Data,
        videoViewer: Data,
        videoServer: Data,
        secondaryVideoViewer: Data? = nil,
        secondaryVideoServer: Data? = nil
    ) {
        self.audioViewer = audioViewer
        self.audioServer = audioServer
        self.videoViewer = videoViewer
        self.videoServer = videoServer
        self.secondaryVideoViewer = secondaryVideoViewer
        self.secondaryVideoServer = secondaryVideoServer
    }

    static func random(includeSecondaryVideo: Bool = false) throws -> AppleMediaKeys {
        try AppleMediaKeys(
            audioViewer: Cryptography.randomBytes(count: blobLength),
            audioServer: Cryptography.randomBytes(count: blobLength),
            videoViewer: Cryptography.randomBytes(count: blobLength),
            videoServer: Cryptography.randomBytes(count: blobLength),
            secondaryVideoViewer: includeSecondaryVideo ? Cryptography.randomBytes(count: blobLength) : nil,
            secondaryVideoServer: includeSecondaryVideo ? Cryptography.randomBytes(count: blobLength) : nil
        )
    }

    func validate() throws {
        let secondaryKeys = [secondaryVideoViewer, secondaryVideoServer].compactMap { $0 }
        guard [audioViewer, audioServer, videoViewer, videoServer].allSatisfy({ $0.count == Self.blobLength }),
              secondaryKeys.count != 1,
              secondaryKeys.allSatisfy({ $0.count == Self.blobLength }) else {
            throw AppleMediaConfigurationError.invalidKeyLength
        }
    }
}

struct AppleCanvas: Equatable, Hashable, Sendable {
    let width: Int
    let height: Int
    let tileCount: Int

    var isUsable: Bool { width > 0 && height > 0 }
}

enum AppleMediaAnswer: Equatable, Sendable {
    case unrelated
    case degenerate
    case canvas(AppleCanvas)
}

enum AppleMediaConfiguration {
    static func message(
        audioOffer: Data,
        videoOffer: Data,
        secondaryVideoOffer: Data? = nil,
        keys: AppleMediaKeys,
        callID: UUID = UUID()
    ) throws -> Data {
        try keys.validate()
        let secondaryVideoOffer = secondaryVideoOffer ?? Data()
        let hasSecondaryKeys = keys.secondaryVideoViewer != nil && keys.secondaryVideoServer != nil
        guard secondaryVideoOffer.isEmpty != hasSecondaryKeys else {
            throw AppleMediaConfigurationError.invalidSecondaryVideo
        }
        let messageSize = audioOffer.count + videoOffer.count + secondaryVideoOffer.count
            + 0xd8 + (secondaryVideoOffer.isEmpty ? 0 : 2 * AppleMediaKeys.blobLength)
        guard audioOffer.count <= Int(UInt16.max),
              videoOffer.count <= Int(UInt16.max),
              secondaryVideoOffer.count <= Int(UInt16.max),
              messageSize <= Int(UInt16.max) else {
            throw AppleMediaConfigurationError.offerTooLarge
        }

        var message = Data(repeating: 0, count: messageSize + 4)
        message[0] = 0x1c
        message.writeUInt16BE(UInt16(messageSize), at: 2)
        message.writeUInt16BE(3, at: 4)
        message[6] = secondaryVideoOffer.isEmpty ? 0x05 : 0x07
        message.writeUInt16BE(UInt16(audioOffer.count), at: 10)
        message.writeUInt16BE(UInt16(videoOffer.count), at: 12)
        message.writeUInt16BE(UInt16(secondaryVideoOffer.count), at: 14)
        withUnsafeBytes(of: callID.uuid) { message.replaceSubrange(0x14..<0x24, with: $0) }
        message.replaceSubrange(0x24..<0x52, with: keys.audioViewer)
        message.replaceSubrange(0x52..<0x80, with: keys.audioServer)
        message.replaceSubrange(0x80..<(0x80 + audioOffer.count), with: audioOffer)
        let videoOffset = 0x80 + audioOffer.count
        message.replaceSubrange(videoOffset..<(videoOffset + 0x2e), with: keys.videoViewer)
        message.replaceSubrange((videoOffset + 0x2e)..<(videoOffset + 0x5c), with: keys.videoServer)
        message.replaceSubrange(
            (videoOffset + 0x5c)..<(videoOffset + 0x5c + videoOffer.count),
            with: videoOffer
        )
        if let secondaryVideoViewer = keys.secondaryVideoViewer,
           let secondaryVideoServer = keys.secondaryVideoServer,
           !secondaryVideoOffer.isEmpty {
            let offset = videoOffset + 0x5c + videoOffer.count
            message.replaceSubrange(offset..<(offset + 0x2e), with: secondaryVideoViewer)
            message.replaceSubrange((offset + 0x2e)..<(offset + 0x5c), with: secondaryVideoServer)
            message.replaceSubrange(
                (offset + 0x5c)..<(offset + 0x5c + secondaryVideoOffer.count),
                with: secondaryVideoOffer
            )
        }
        return message
    }

    static func canvas(from answer: Data) -> AppleCanvas? {
        guard case let .canvas(canvas) = answerStatus(from: answer) else { return nil }
        return canvas
    }

    static func answerStatus(from answer: Data) -> AppleMediaAnswer {
        guard answer.first == 0 else { return .unrelated }
        if let canvas = canvases(from: answer).first { return .canvas(canvas) }
        return containsMediaAnswer(in: answer) ? .degenerate : .unrelated
    }

    static func canvases(from answer: Data) -> [AppleCanvas] {
        guard answer.first == 0 else { return [] }
        let signature = Data("bplist".utf8)
        var searchStart = answer.startIndex
        var result = [AppleCanvas]()
        while searchStart < answer.endIndex,
              let range = answer.range(of: signature, in: searchStart..<answer.endIndex) {
            for end in stride(from: answer.endIndex, through: range.upperBound, by: -1) {
                let plistData = answer.subdata(in: range.lowerBound..<end)
                guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil),
                      let dictionary = plist as? [String: Any],
                      let compressed = dictionary["avcMediaStreamNegotiatorMediaBlob"] as? Data else { continue }
                guard let blob = try? AppleMediaOffer.decompressMediaBlob(compressed),
                      let canvas = canvas(fromProtobuf: blob), canvas.isUsable else { continue }
                result.append(canvas)
                break
            }
            searchStart = range.upperBound
        }
        return result
    }

    private static func containsMediaAnswer(in answer: Data) -> Bool {
        answer.range(of: Data("avcMediaStreamNegotiatorMediaBlob".utf8)) != nil
    }

    private static func canvas(fromProtobuf data: Data) -> AppleCanvas? {
        var reader = ProtobufReader(data: data)
        while let field = reader.next() {
            if field.number == 5, case let .bytes(value) = field.value {
                var width = 0
                var height = 0
                var tiles = 0
                var nested = ProtobufReader(data: value)
                while let item = nested.next() {
                    guard case let .varint(value) = item.value else { continue }
                    if item.number == 4 { width = Int(value) }
                    if item.number == 5 { height = Int(value) }
                    if item.number == 6 { tiles = Int(value) }
                }
                let canvas = AppleCanvas(width: width, height: height, tileCount: tiles)
                if canvas.isUsable { return canvas }
            }
        }
        return nil
    }
}

private struct ProtobufReader {
    enum Value { case varint(UInt64), bytes(Data) }
    struct Field { let number: Int; let value: Value }

    let data: Data
    var offset = 0

    mutating func next() -> Field? {
        guard let tag = readVarint() else { return nil }
        let number = Int(tag >> 3)
        switch tag & 7 {
        case 0:
            guard let value = readVarint() else { return nil }
            return Field(number: number, value: .varint(value))
        case 1:
            guard skip(8) else { return nil }
        case 2:
            guard let length = readVarint(), length <= UInt64(Int.max),
                  let bytes = read(Int(length)) else { return nil }
            return Field(number: number, value: .bytes(bytes))
        case 5:
            guard skip(4) else { return nil }
        default:
            return nil
        }
        return next()
    }

    private mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard offset < data.count else { return nil }
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7f) << UInt64(shift)
            if byte & 0x80 == 0 { return result }
        }
        return nil
    }

    private mutating func read(_ count: Int) -> Data? {
        guard count >= 0, offset <= data.count - count else { return nil }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    private mutating func skip(_ count: Int) -> Bool { read(count) != nil }
}

enum AppleMediaConfigurationError: LocalizedError, Equatable {
    case invalidKeyLength
    case invalidSecondaryVideo
    case offerTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidKeyLength: "The media encryption key has an invalid length."
        case .invalidSecondaryVideo: "The second display media offer is incomplete."
        case .offerTooLarge: "The media negotiation offer is too large."
        }
    }
}
