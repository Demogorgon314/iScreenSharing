import Foundation

struct AppleMediaOffers: Equatable, Sendable {
    let video: Data
    let audio: Data
    let videoSynchronizationSource: UInt32
    let audioSynchronizationSource: UInt32
}

enum AppleMediaOffer {
    /// Keep the decoder's control-feature map identical to the PT 100 offer.
    /// The server may encode tile positions with POSE rather than POS, and VCP
    /// needs both entries to strip and interpret the private HEVC suffix.
    static let videoDecoderNegotiationDetails =
        "FLS;LF:-1;POS:5;EOD:1;HTS:2;RR:3;POSE:4;AR:16/9,5/8;XR:16/9,5/8;"

    private static let hevcParameters = Data(
        "FLS;MS:-1;LF:-1;LTR;CABAC;POS:0;EOD:1;HTS:2;RR:3;AR:16/9,5/8;XR:16/9,5/8;".utf8
    )
    private static let avcParameters = Data(videoDecoderNegotiationDetails.utf8)
    private static let audioTiers: [(UInt64, UInt64, UInt64?)] = [
        (0, 40_000_000, 12_288), (0, 6_000_000, 131_072), (4_074, 0, 16_384),
        (16, 4_100, nil), (0, 75_000_000, 524_288), (0, 20_000_000, 98_304),
        (4, 6_500, nil), (0, 60_000_000, 262_144), (1, 299, nil),
        (0, 100_000_000, 1_048_576),
    ]

    static func create(
        audioEnabled: Bool = true,
        randomUInt32: () throws -> UInt32 = { try Cryptography.randomUInt32() },
        timestamp: () -> UInt64 = { UInt64(Date().timeIntervalSince1970 * 1_000_000_000) },
        uuid: () -> UUID = UUID.init
    ) throws -> AppleMediaOffers {
        let videoSynchronizationSource = try randomUInt32()
        let audioSynchronizationSource = try randomUInt32()
        let video = try makePlist(
            mode: 7,
            sessionID: videoSynchronizationSource,
            timestamp: timestamp(),
            callID: uuid(),
            audioEnabled: audioEnabled
        )
        let audio = try makePlist(
            mode: 8,
            sessionID: audioSynchronizationSource,
            timestamp: timestamp(),
            callID: uuid(),
            audioEnabled: audioEnabled
        )
        return AppleMediaOffers(
            video: video,
            audio: audio,
            videoSynchronizationSource: videoSynchronizationSource,
            audioSynchronizationSource: audioSynchronizationSource
        )
    }

    static func decompressMediaBlob(from offer: Data) throws -> Data {
        let plist = try PropertyListSerialization.propertyList(from: offer, format: nil)
        guard let dictionary = plist as? [String: Any],
              let compressed = dictionary["avcMediaStreamNegotiatorMediaBlob"] as? Data else {
            throw AppleMediaOfferError.invalidPropertyList
        }
        return try decompressMediaBlob(compressed)
    }

    static func decompressMediaBlob(_ compressed: Data) throws -> Data {
        try ZlibCodec.decompress(compressed)
    }

    private static func makePlist(
        mode: Int,
        sessionID: UInt32,
        timestamp: UInt64,
        callID: UUID,
        audioEnabled: Bool
    ) throws -> Data {
        let blob = mediaBlob(
            mode: mode,
            sessionID: sessionID,
            timestamp: timestamp,
            audioEnabled: audioEnabled
        )
        let dictionary: [String: Any] = [
            "avcMediaStreamOptionRemoteEndpointInfo": remoteEndpointInfo(),
            "avcMediaStreamNegotiatorMode": mode,
            "avcMediaStreamNegotiatorMediaBlob": try ZlibCodec.compress(blob),
            "avcMediaStreamOptionCallID": callID.uuidString.uppercased(),
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .binary,
            options: 0
        )
    }

    private static func mediaBlob(
        mode: Int,
        sessionID: UInt32,
        timestamp: UInt64,
        audioEnabled: Bool
    ) -> Data {
        let description: Data
        let descriptionField: Int
        if mode == 7 {
            let standardResolution = protobuf([
                .varint(1, 1), .varint(2, 1), .varint(3, 50_115), .varint(4, 0),
            ])
            let alternateResolution = protobuf([
                .varint(1, 1), .varint(2, 2), .varint(3, 50_115), .varint(4, 0),
            ])
            let h264OutputBank = protobuf([
                .varint(1, 123),
                .bytes(2, standardResolution), .bytes(2, alternateResolution),
                .bytes(2, standardResolution), .bytes(2, alternateResolution),
                .bytes(3, hevcParameters), .varint(4, 1),
            ])
            let hevcOutputBank = protobuf([
                .varint(1, 100), .bytes(2, standardResolution), .bytes(2, alternateResolution),
                .bytes(3, avcParameters), .varint(4, 14),
            ])
            description = protobuf([
                .varint(1, UInt64(sessionID)), .varint(2, 1),
                .bytes(3, h264OutputBank), .bytes(3, hevcOutputBank),
                .varint(6, 4), .varint(7, 1), .varint(8, 63),
                .varint(9, 1), .varint(12, 1),
            ])
            descriptionField = 5
        } else {
            description = protobuf([
                .varint(1, UInt64(sessionID)), .varint(2, 0), .varint(3, 0),
                .varint(4, audioEnabled ? 24_191 : 1_000),
                .varint(5, 0), .varint(6, 0),
            ])
            descriptionField = 3
        }

        var fields: [ProtobufField] = [
            .varint(1, 1), .varint(2, 1), .bytes(descriptionField, description),
            .bytes(6, Data("iShareScreen 0.1.0".utf8)), .varint(8, 0),
        ]
        fields.append(contentsOf: audioTiers.map { kind, bitrate, capacity in
            var tier: [ProtobufField] = [.varint(1, kind), .varint(2, bitrate)]
            if let capacity { tier.append(.varint(3, capacity)) }
            return .bytes(9, protobuf(tier))
        })
        fields.append(contentsOf: [
            .varint(13, timestamp), .varint(14, 2), .varint(16, 0), .varint(18, 1),
        ])
        return protobuf(fields)
    }

    private static func remoteEndpointInfo() -> Data {
        let processInfo = ProcessInfo.processInfo
        return protobuf([
            .varint(1, 0), .varint(2, 1),
            .bytes(3, Data("Mac".utf8)),
            .bytes(4, Data("1.0.0".utf8)),
            .bytes(5, Data(processInfo.operatingSystemVersionString.prefix(127).utf8)),
        ])
    }

    private enum ProtobufField {
        case varint(Int, UInt64)
        case bytes(Int, Data)
    }

    private static func protobuf(_ fields: [ProtobufField]) -> Data {
        var data = Data()
        for field in fields {
            switch field {
            case let .varint(number, value):
                data.append(varint(UInt64(number << 3)))
                data.append(varint(value))
            case let .bytes(number, value):
                data.append(varint(UInt64((number << 3) | 2)))
                data.append(varint(UInt64(value.count)))
                data.append(value)
            }
        }
        return data
    }

    private static func varint(_ value: UInt64) -> Data {
        var value = value
        var data = Data()
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            data.append(byte)
        } while value != 0
        return data
    }
}

enum AppleMediaOfferError: LocalizedError {
    case invalidPropertyList
    case compressionFailed

    var errorDescription: String? {
        switch self {
        case .invalidPropertyList: "The media offer property list is invalid."
        case .compressionFailed: "The media offer could not be compressed."
        }
    }
}
