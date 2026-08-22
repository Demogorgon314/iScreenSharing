import CoreMedia
import CoreVideo
import Darwin
import Foundation
import VideoToolbox

/// Thin, runtime-loaded wrapper around the same private VideoProcessing
/// decompression entry points used by Screen Sharing.app. Keeping the symbols
/// behind `dlopen` lets unsupported systems fall back to public VideoToolbox.
final class AppleVCPDecompressionSession: @unchecked Sendable {
    struct FrameMetadata: Sendable {
        let tileIndex: Int
        let tileOrder: UInt16
        let decodingOrderNumber: UInt16?
        let rtpTimestamp: UInt32
        let presentationTime: TimeInterval
        let decodeStartedAt: TimeInterval
    }

    typealias FrameHandler = @Sendable (FrameMetadata, CVPixelBuffer) -> Void

    private final class CallbackContext: @unchecked Sendable {
        let frameHandler: FrameHandler

        init(frameHandler: @escaping FrameHandler) {
            self.frameHandler = frameHandler
        }
    }

    private final class SourceFrameContext: @unchecked Sendable {
        let metadata: FrameMetadata

        init(metadata: FrameMetadata) {
            self.metadata = metadata
        }
    }

    private static let videoProcessingPath =
        "/System/Library/PrivateFrameworks/VideoProcessing.framework/Versions/A/VideoProcessing"
    private static let tileIDKey = "TileID" as CFString
    private static let tileOrderKey = "TileOrder" as CFString
    private static let rtpTimestampKey = "rtpTimestsamp" as CFString
    private static let subframeIdentifierKey = "subFrameIndentifier" as CFString
    private static let framePriorityKey = "FramePriority" as CFString
    private static let functions = Functions.load()

    private let functions: Functions
    private let callbackContext: CallbackContext
    private var session: OpaquePointer?

    static var isAvailable: Bool {
        functions != nil
            && ProcessInfo.processInfo.environment["ISHARESCREEN_DISABLE_VCP"] != "1"
    }

    init?(
        formatDescription: CMVideoFormatDescription,
        tileCount: Int,
        negotiationDetails: String,
        nativePixelFormat: OSType,
        frameHandler: @escaping FrameHandler
    ) {
        guard tileCount > 1,
              Self.isAvailable,
              let functions = Self.functions else { return nil }

        self.functions = functions
        callbackContext = CallbackContext(frameHandler: frameHandler)

        let decoderSpecification = Self.decoderSpecification(
            tileCount: tileCount,
            negotiationDetails: negotiationDetails
        )
        let imageBufferAttributes = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: nativePixelFormat),
        ] as CFDictionary
        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: Self.outputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(callbackContext).toOpaque()
        )
        var createdSession: OpaquePointer?
        var status = functions.create(
            kCFAllocatorDefault,
            formatDescription,
            decoderSpecification,
            imageBufferAttributes,
            &callbackRecord,
            &createdSession
        )
        if status != noErr || createdSession == nil {
            status = functions.create(
                kCFAllocatorDefault,
                formatDescription,
                decoderSpecification,
                nil,
                &callbackRecord,
                &createdSession
            )
        }
        guard status == noErr, let createdSession else { return nil }
        session = createdSession
    }

    @discardableResult
    func decode(
        _ sampleBuffer: CMSampleBuffer,
        metadata: FrameMetadata,
        flags: VTDecodeFrameFlags
    ) throws -> Bool {
        guard let session else { throw AppleVCPDecompressionSessionError.sessionClosed }
        Self.attachMetadata(metadata, to: sampleBuffer)
        let sourceContext = Unmanaged.passRetained(SourceFrameContext(metadata: metadata))
        var infoFlags: UInt32 = 0
        let status = functions.decode(
            session,
            sampleBuffer,
            flags.rawValue,
            sourceContext.toOpaque(),
            &infoFlags
        )
        guard status == noErr else {
            sourceContext.release()
            throw AppleVCPDecompressionSessionError.decodeFailed(status)
        }
        return true
    }

    func close() {
        guard let session else { return }
        self.session = nil
        _ = functions.waitForAsynchronousFrames(session)
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(session)).release()
    }

    deinit {
        close()
    }

    static func subframeIdentifier(tileID: Int, tileOrder: UInt16) -> Int64 {
        Int64(bitPattern: (UInt64(UInt32(truncatingIfNeeded: tileID)) << 32) | UInt64(tileOrder))
    }

    static func decoderSpecification(
        tileCount: Int,
        negotiationDetails: String
    ) -> CFDictionary {
        [
            "NegotiationDetails": negotiationDetails,
            "NumberOfTiles": NSNumber(value: Int64(tileCount)),
        ] as CFDictionary
    }

    private static let outputCallback: VTDecompressionOutputCallback = {
        outputRefCon,
        sourceFrameRefCon,
        status,
        _,
        imageBuffer,
        _,
        _ in
        guard let sourceFrameRefCon else { return }
        let source = Unmanaged<SourceFrameContext>
            .fromOpaque(sourceFrameRefCon)
            .takeRetainedValue()
        guard let outputRefCon else { return }
        let callback = Unmanaged<CallbackContext>
            .fromOpaque(outputRefCon)
            .takeUnretainedValue()
        guard status == noErr, let imageBuffer else { return }
        callback.frameHandler(source.metadata, imageBuffer)
    }

    private static func attachMetadata(
        _ metadata: FrameMetadata,
        to sampleBuffer: CMSampleBuffer
    ) {
        if let array = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ), CFArrayGetCount(array) > 0 {
            let dictionary = unsafeBitCast(
                CFArrayGetValueAtIndex(array, 0),
                to: CFMutableDictionary.self
            )
            if let tileID = makeNumber(
                Int32(truncatingIfNeeded: metadata.tileIndex),
                type: .sInt32Type
            ) {
                set(tileID, for: tileIDKey, in: dictionary)
            }
            if let tileOrder = makeNumber(Int32(metadata.tileOrder), type: .sInt32Type) {
                set(tileOrder, for: tileOrderKey, in: dictionary)
            }
        }

        var rtpTimestamp = Int32(bitPattern: metadata.rtpTimestamp)
        if let value = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &rtpTimestamp) {
            CMSetAttachment(
                sampleBuffer,
                key: rtpTimestampKey,
                value: value,
                attachmentMode: kCMAttachmentMode_ShouldNotPropagate
            )
        }
        var subframeIdentifier = subframeIdentifier(
            tileID: metadata.tileIndex,
            tileOrder: metadata.tileOrder
        )
        if let value = CFNumberCreate(kCFAllocatorDefault, .sInt64Type, &subframeIdentifier) {
            CMSetAttachment(
                sampleBuffer,
                key: subframeIdentifierKey,
                value: value,
                attachmentMode: kCMAttachmentMode_ShouldNotPropagate
            )
        }
        var framePriority: Int8 = 0
        if let value = CFNumberCreate(kCFAllocatorDefault, .charType, &framePriority) {
            CMSetAttachment(
                sampleBuffer,
                key: framePriorityKey,
                value: value,
                attachmentMode: kCMAttachmentMode_ShouldPropagate
            )
        }
    }

    private static func makeNumber<T>(_ value: T, type: CFNumberType) -> CFNumber? {
        var value = value
        return withUnsafePointer(to: &value) {
            CFNumberCreate(kCFAllocatorDefault, type, $0)
        }
    }

    private static func set(
        _ value: CFTypeRef,
        for key: CFString,
        in dictionary: CFMutableDictionary
    ) {
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(key).toOpaque(),
            Unmanaged.passUnretained(value).toOpaque()
        )
    }

    private struct Functions: @unchecked Sendable {
        typealias Create = @convention(c) (
            CFAllocator?,
            CMVideoFormatDescription,
            CFDictionary?,
            CFDictionary?,
            UnsafePointer<VTDecompressionOutputCallbackRecord>?,
            UnsafeMutablePointer<OpaquePointer?>
        ) -> OSStatus
        typealias Decode = @convention(c) (
            OpaquePointer,
            CMSampleBuffer,
            UInt32,
            UnsafeMutableRawPointer?,
            UnsafeMutablePointer<UInt32>?
        ) -> OSStatus
        typealias Wait = @convention(c) (OpaquePointer) -> OSStatus
        let libraryHandle: UnsafeMutableRawPointer
        let create: Create
        let decode: Decode
        let waitForAsynchronousFrames: Wait

        static func load() -> Functions? {
            guard let handle = dlopen(videoProcessingPath, RTLD_LAZY | RTLD_LOCAL) else {
                return nil
            }
            guard let create = symbol(
                "VCPDecompressionSessionCreate",
                as: Create.self,
                in: handle
            ), let decode = symbol(
                "VCPDecompressionSessionDecodeFrame",
                as: Decode.self,
                in: handle
            ), let wait = symbol(
                "VCPDecompressionSessionWaitForAsynchronousFrames",
                as: Wait.self,
                in: handle
            ) else {
                dlclose(handle)
                return nil
            }
            return Functions(
                libraryHandle: handle,
                create: create,
                decode: decode,
                waitForAsynchronousFrames: wait
            )
        }

        private static func symbol<T>(
            _ name: String,
            as type: T.Type,
            in handle: UnsafeMutableRawPointer
        ) -> T? {
            guard let address = dlsym(handle, name) else { return nil }
            return unsafeBitCast(address, to: type)
        }
    }
}

enum AppleVCPDecompressionSessionError: LocalizedError, Equatable {
    case decodeFailed(OSStatus)
    case sessionClosed

    var errorDescription: String? {
        switch self {
        case .decodeFailed:
            "The private multi-tile decoder rejected a remote video frame."
        case .sessionClosed:
            "The private multi-tile decoder is no longer active."
        }
    }
}
