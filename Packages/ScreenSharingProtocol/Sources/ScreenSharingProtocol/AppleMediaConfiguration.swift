import Foundation

public struct AppleMediaKeys: Equatable, Sendable {
    public static let blobLength = 46

    public let audioViewer: Data
    public let audioServer: Data
    public let videoViewer: Data
    public let videoServer: Data
    public let secondaryVideoViewer: Data?
    public let secondaryVideoServer: Data?

    public init(
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

    public func validate() throws {
        let secondaryKeys = [secondaryVideoViewer, secondaryVideoServer].compactMap { $0 }
        guard [audioViewer, audioServer, videoViewer, videoServer].allSatisfy({ $0.count == Self.blobLength }),
              secondaryKeys.count != 1,
              secondaryKeys.allSatisfy({ $0.count == Self.blobLength }) else {
            throw AppleMediaConfigurationError.invalidKeyLength
        }
    }
}

public struct AppleCanvas: Equatable, Hashable, Sendable {
    public let width: Int
    public let height: Int
    public let tileCount: Int

    public init(width: Int, height: Int, tileCount: Int) {
        self.width = width
        self.height = height
        self.tileCount = tileCount
    }

    public var isUsable: Bool { width > 0 && height > 0 }
}

public struct AppleMediaPorts: Equatable, Sendable {
    public let audio: UInt16
    public let videos: [UInt16]

    public init(audio: UInt16, videos: [UInt16]) {
        self.audio = audio
        self.videos = videos
    }
}

public enum AppleMediaAnswer: Equatable, Sendable {
    case unrelated
    case degenerate
    case canvas(AppleCanvas)
}

public enum AppleMediaConfiguration {
    public static func message(
        audioOffer: Data,
        videoOffer: Data,
        secondaryVideoOffer: Data? = nil,
        keys: AppleMediaKeys,
        callID: UUID
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
        precondition(BigEndianWire.write(UInt16(messageSize), to: &message, at: 2))
        precondition(BigEndianWire.write(UInt16(3), to: &message, at: 4))
        // Bit 0 enables 60 FPS for video 1, bit 1 does the same for video 2,
        // and bit 2 tells the server not to composite its cursor into video.
        let flags: UInt32 = secondaryVideoOffer.isEmpty ? 0x05 : 0x07
        precondition(BigEndianWire.write(flags, to: &message, at: 6))
        precondition(BigEndianWire.write(UInt16(audioOffer.count), to: &message, at: 10))
        precondition(BigEndianWire.write(UInt16(videoOffer.count), to: &message, at: 12))
        precondition(BigEndianWire.write(UInt16(secondaryVideoOffer.count), to: &message, at: 14))
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

    public static func canvas(from answer: Data) -> AppleCanvas? {
        guard case let .canvas(canvas) = answerStatus(from: answer) else { return nil }
        return canvas
    }

    public static func answerStatus(from answer: Data) -> AppleMediaAnswer {
        guard answer.first == 0 else { return .unrelated }
        if let canvas = canvases(from: answer).first { return .canvas(canvas) }
        return containsMediaAnswer(in: answer) ? .degenerate : .unrelated
    }

    public static func ports(from answer: Data) -> AppleMediaPorts? {
        guard answer.count >= 0x14,
              BigEndianWire.uint16(from: answer, at: 2) == 1,
              let version = BigEndianWire.uint16(from: answer, at: 4), version != 0,
              let audio = BigEndianWire.uint16(from: answer, at: 0x0a), audio != 0,
              let primaryVideo = BigEndianWire.uint16(from: answer, at: 0x10), primaryVideo != 0,
              BigEndianWire.uint16(from: answer, at: 0x12) == 1 else { return nil }
        var videos = [primaryVideo]
        if answer.count > 0x18, answer[0x18] & 1 != 0 {
            guard let secondaryVideo = BigEndianWire.uint16(from: answer, at: 0x16),
                  secondaryVideo != 0 else {
                return nil
            }
            videos.append(secondaryVideo)
        }
        return AppleMediaPorts(audio: audio, videos: videos)
    }

    public static func canvases(from answer: Data) -> [AppleCanvas] {
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

public enum AppleMediaConfigurationError: LocalizedError, Equatable {
    case invalidKeyLength
    case invalidSecondaryVideo
    case offerTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidKeyLength: "The media encryption key has an invalid length."
        case .invalidSecondaryVideo: "The second display media offer is incomplete."
        case .offerTooLarge: "The media negotiation offer is too large."
        }
    }
}
