import AVFAudio
import AudioToolbox
import Foundation

protocol AppleAudioDecoding: AnyObject {
    func decode(_ accessUnit: Data) throws -> AVAudioPCMBuffer?
}

final class AppleAACELDDecoder: AppleAudioDecoding, @unchecked Sendable {
    static let sampleRate = 48_000.0
    static let channelCount: AVAudioChannelCount = 2
    static let framesPerPacket: AVAudioFrameCount = 480
    static let magicCookie = Data([
        0x03, 0x80, 0x80, 0x80, 0x26, 0x00, 0x00, 0x00,
        0x04, 0x80, 0x80, 0x80, 0x18, 0x40, 0x14, 0x00,
        0x18, 0x00, 0x00, 0x01, 0x38, 0x80, 0x00, 0x00,
        0x00, 0x00, 0x05, 0x80, 0x80, 0x80, 0x06, 0xf8,
        0xe6, 0x51, 0x32, 0xe0, 0x00, 0x06, 0x80, 0x80,
        0x80, 0x01, 0x02,
    ])

    let outputFormat: AVAudioFormat
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init() throws {
        var inputDescription = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatMPEG4AAC_ELD_SBR,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: Self.framesPerPacket,
            mBytesPerFrame: 0,
            mChannelsPerFrame: Self.channelCount,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let inputFormat = AVAudioFormat(streamDescription: &inputDescription),
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.sampleRate,
                channels: Self.channelCount,
                interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AppleAACELDDecoderError.converterCreationFailed
        }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
        converter.magicCookie = Self.magicCookie
        converter.primeMethod = .none
    }

    func decode(_ accessUnit: Data) throws -> AVAudioPCMBuffer? {
        guard !accessUnit.isEmpty, accessUnit.count <= 65_535 else {
            throw AppleAACELDDecoderError.invalidAccessUnit
        }
        let input = AVAudioCompressedBuffer(
            format: inputFormat,
            packetCapacity: 1,
            maximumPacketSize: accessUnit.count
        )
        accessUnit.copyBytes(to: input.data.assumingMemoryBound(to: UInt8.self), count: accessUnit.count)
        input.byteLength = UInt32(accessUnit.count)
        input.packetCount = 1
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(accessUnit.count)
        )

        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: Self.framesPerPacket
        ) else { throw AppleAACELDDecoderError.outputBufferCreationFailed }
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        guard conversionError == nil, status != .error else {
            throw AppleAACELDDecoderError.decodeFailed(conversionError?.code ?? -1)
        }
        return output.frameLength > 0 ? output : nil
    }
}

enum AppleAACELDDecoderError: LocalizedError, Equatable {
    case converterCreationFailed
    case invalidAccessUnit
    case outputBufferCreationFailed
    case decodeFailed(Int)

    var errorDescription: String? {
        switch self {
        case .converterCreationFailed:
            "The Mac could not prepare its AAC-ELD audio decoder."
        case .invalidAccessUnit, .decodeFailed:
            "A remote audio packet could not be decoded."
        case .outputBufferCreationFailed:
            "The Mac could not allocate an audio output buffer."
        }
    }
}
