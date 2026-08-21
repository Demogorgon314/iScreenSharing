import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class AppleHEVCDecoder: @unchecked Sendable {
    typealias FrameHandler = @Sendable (Int, UInt16?, CVPixelBuffer) -> Void

    static let nativePixelFormat = OSType(0x3434_3466) // '444f' (NV24)

    private let lock = NSLock()
    private let formatDescription: CMVideoFormatDescription
    private let frameHandler: FrameHandler
    private var session: VTDecompressionSession?

    init(parameterSets: AppleHEVCParameterSets, frameHandler: @escaping FrameHandler) throws {
        guard parameterSets.isComplete else { throw AppleHEVCDecoderError.incompleteParameterSets }
        formatDescription = try Self.makeFormatDescription(parameterSets)
        self.frameHandler = frameHandler
        session = try Self.makeSession(formatDescription: formatDescription)
    }

    @discardableResult
    func decode(_ nalUnit: Data, tileIndex: Int, decodingOrderNumber: UInt16?) throws -> Bool {
        guard let type = AppleHEVCNALUnit.type(of: nalUnit), type < 32 else { return false }
        let sampleBuffer = try Self.makeSampleBuffer(
            nalUnit: nalUnit,
            formatDescription: formatDescription
        )
        return try lock.withDecoderLock {
            guard let session else { throw AppleHEVCDecoderError.sessionClosed }
            var decodeInfo = VTDecodeInfoFlags()
            let status = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags: [],
                infoFlagsOut: &decodeInfo
            ) { [frameHandler] status, _, imageBuffer, _, _ in
                guard status == noErr, let imageBuffer else { return }
                frameHandler(tileIndex, decodingOrderNumber, imageBuffer)
            }
            guard status == noErr else { throw AppleHEVCDecoderError.decodeFailed(status) }
            return true
        }
    }

    func close() {
        lock.withDecoderLock {
            guard let session else { return }
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
    }

    deinit {
        close()
    }

    static func lengthPrefixedPayload(for nalUnit: Data) throws -> Data {
        guard !nalUnit.isEmpty, nalUnit.count <= Int(UInt32.max) else {
            throw AppleHEVCDecoderError.invalidNALUnit
        }
        var payload = Data()
        payload.appendUInt32BE(UInt32(nalUnit.count))
        payload.append(nalUnit)
        return payload
    }

    private static func makeFormatDescription(
        _ parameterSets: AppleHEVCParameterSets
    ) throws -> CMVideoFormatDescription {
        let data = [parameterSets.video, parameterSets.sequence] + parameterSets.pictures
        let retainedData = data.map { $0 as NSData }
        var pointers = retainedData.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        var sizes = retainedData.map(\.length)
        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: pointers.count,
            parameterSetPointers: &pointers,
            parameterSetSizes: &sizes,
            nalUnitHeaderLength: 4,
            extensions: nil,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw AppleHEVCDecoderError.formatDescriptionCreationFailed(status)
        }
        return description
    }

    private static func makeSession(
        formatDescription: CMVideoFormatDescription
    ) throws -> VTDecompressionSession {
        var session: VTDecompressionSession?
        let attributes = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: nativePixelFormat),
        ] as CFDictionary
        var status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attributes,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        if status != noErr || session == nil {
            status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: formatDescription,
                decoderSpecification: nil,
                imageBufferAttributes: nil,
                outputCallback: nil,
                decompressionSessionOut: &session
            )
        }
        guard status == noErr, let session else {
            throw AppleHEVCDecoderError.sessionCreationFailed(status)
        }
        return session
    }

    private static func makeSampleBuffer(
        nalUnit: Data,
        formatDescription: CMVideoFormatDescription
    ) throws -> CMSampleBuffer {
        let payload = try lengthPrefixedPayload(for: nalUnit)
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw AppleHEVCDecoderError.sampleBufferCreationFailed(status)
        }
        status = payload.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: payload.count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw AppleHEVCDecoderError.sampleBufferCreationFailed(status)
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = payload.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw AppleHEVCDecoderError.sampleBufferCreationFailed(status)
        }
        return sampleBuffer
    }
}

enum AppleHEVCDecoderError: LocalizedError, Equatable {
    case incompleteParameterSets
    case invalidNALUnit
    case formatDescriptionCreationFailed(OSStatus)
    case sessionCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
    case decodeFailed(OSStatus)
    case sessionClosed

    var errorDescription: String? {
        switch self {
        case .incompleteParameterSets:
            "The remote Mac did not provide complete HEVC decoder parameters."
        case .invalidNALUnit:
            "The remote Mac sent an invalid HEVC video unit."
        case .formatDescriptionCreationFailed, .sessionCreationFailed:
            "The Mac could not prepare its hardware video decoder."
        case .sampleBufferCreationFailed, .decodeFailed:
            "A remote video frame could not be decoded."
        case .sessionClosed:
            "The remote video decoder is no longer active."
        }
    }
}

private extension NSLock {
    func withDecoderLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
