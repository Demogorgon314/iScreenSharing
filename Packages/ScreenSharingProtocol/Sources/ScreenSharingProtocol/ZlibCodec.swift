import Compression
import Foundation
import zlib

public enum ZlibCodec {
    public static let defaultMaximumOutputLength = 16 * 1_024 * 1_024

    public static func compress(
        _ input: Data,
        maximumOutputLength: Int = defaultMaximumOutputLength
    ) throws -> Data {
        guard maximumOutputLength >= 6 else { throw ZlibCodecError.outputTooLarge }
        let deflate = try transform(
            input,
            initialCapacity: min(maximumOutputLength - 6, max(256, input.count)),
            maximumOutputLength: maximumOutputLength - 6,
            function: compression_encode_buffer
        )
        var output = Data([0x78, 0x9c])
        output.append(deflate)
        BigEndianWire.append(adler32(input), to: &output)
        return output
    }

    /// Produces the unterminated zlib stream used by Apple's clipboard and drag-and-drop
    /// messages: one level-9 deflate call with `Z_SYNC_FLUSH` and no Adler-32
    /// trailer. This is intentionally distinct from the completed stream
    /// produced by `compress`.
    public static func compressSyncFlush(
        _ input: Data,
        maximumOutputLength: Int = defaultMaximumOutputLength
    ) throws -> Data {
        try ZlibSyncFlushCompressor().compress(
            input,
            maximumOutputLength: maximumOutputLength
        )
    }

    public static func decompress(_ input: Data) throws -> Data {
        guard input.count >= 6, hasValidHeader(input), input[1] & 0x20 == 0 else {
            throw ZlibCodecError.invalidStream
        }
        let deflate = input.subdata(in: 2..<(input.count - 4))
        let output = try transform(
            deflate,
            initialCapacity: max(4_096, input.count * 4),
            maximumOutputLength: defaultMaximumOutputLength,
            function: compression_decode_buffer
        )
        guard let checksum = BigEndianWire.uint32(from: input, at: input.count - 4),
              adler32(output) == checksum else {
            throw ZlibCodecError.invalidStream
        }
        return output
    }

    /// Decodes one independent sync-flush or completed zlib stream. The decoded
    /// byte count must match `expectedSize` and stay within `maximumOutputLength`.
    public static func decompressSyncFlush(
        _ input: Data,
        expectedSize: Int,
        maximumOutputLength: Int = defaultMaximumOutputLength
    ) throws -> Data {
        guard input.count >= 2, hasValidHeader(input), input[1] & 0x20 == 0,
              expectedSize >= 0, expectedSize <= maximumOutputLength else {
            throw ZlibCodecError.invalidStream
        }
        let deflate = input.dropFirst(2)
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            != COMPRESSION_STATUS_ERROR else {
            stream.deallocate()
            throw ZlibCodecError.invalidStream
        }
        defer {
            compression_stream_destroy(stream)
            stream.deallocate()
        }

        var output = Data()
        try deflate.withUnsafeBytes { source in
            guard let sourceAddress = source.bindMemory(to: UInt8.self).baseAddress else {
                throw ZlibCodecError.invalidStream
            }
            stream.pointee.src_ptr = sourceAddress
            stream.pointee.src_size = source.count
            let chunkSize = max(4_096, min(65_536, max(expectedSize, 1)))
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
            defer { destination.deallocate() }

            while true {
                stream.pointee.dst_ptr = destination
                stream.pointee.dst_size = chunkSize
                let remainingInput = stream.pointee.src_size
                let status = compression_stream_process(stream, 0)
                guard status != COMPRESSION_STATUS_ERROR else { throw ZlibCodecError.invalidStream }
                let produced = chunkSize - stream.pointee.dst_size
                guard produced <= maximumOutputLength - output.count else {
                    throw ZlibCodecError.outputTooLarge
                }
                if produced > 0 { output.append(destination, count: produced) }
                if status == COMPRESSION_STATUS_END { break }
                guard status == COMPRESSION_STATUS_OK else { throw ZlibCodecError.invalidStream }
                // Consuming all input does not drain the decoder's internal
                // output. A full destination needs another pass, including
                // when a sync-flush stream has no final end marker.
                if stream.pointee.src_size == 0 && produced < chunkSize { break }
                guard produced > 0 || stream.pointee.src_size < remainingInput else {
                    throw ZlibCodecError.invalidStream
                }
            }
        }
        guard output.count == expectedSize else { throw ZlibCodecError.invalidStream }
        return output
    }

    private static func hasValidHeader(_ input: Data) -> Bool {
        input[0] & 0x0f == 8 && (Int(input[0]) << 8 | Int(input[1])).isMultiple(of: 31)
    }

    private static func transform(
        _ input: Data,
        initialCapacity: Int,
        maximumOutputLength: Int,
        function: (UnsafeMutablePointer<UInt8>, Int, UnsafePointer<UInt8>, Int, UnsafeMutableRawPointer?, compression_algorithm) -> Int
    ) throws -> Data {
        guard !input.isEmpty else { throw ZlibCodecError.invalidStream }
        var capacity = max(1, initialCapacity)
        while capacity <= maximumOutputLength {
            let output = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { output.deallocate() }
            let count = input.withUnsafeBytes { sourceBuffer in
                function(
                    output,
                    capacity,
                    sourceBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    input.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
            if count > 0, count < capacity { return Data(bytes: output, count: count) }
            guard capacity < maximumOutputLength else { break }
            capacity = min(maximumOutputLength, capacity * 2)
        }
        throw ZlibCodecError.outputTooLarge
    }

    private static func adler32(_ data: Data) -> UInt32 {
        let modulus: UInt32 = 65_521
        var first: UInt32 = 1
        var second: UInt32 = 0
        for byte in data {
            first = (first + UInt32(byte)) % modulus
            second = (second + first) % modulus
        }
        return second << 16 | first
    }
}

/// Stateful encoder for Apple's unterminated zlib streams. Each call emits one
/// `Z_SYNC_FLUSH` segment while retaining the dictionary for the next call.
/// Instances are intentionally single-owner and are not thread-safe.
public final class ZlibSyncFlushCompressor {
    private var stream = z_stream()

    public init() throws {
        guard deflateInit2_(
            &stream,
            9,
            Z_DEFLATED,
            15,
            9,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            throw ZlibCodecError.invalidStream
        }
    }

    deinit {
        deflateEnd(&stream)
    }

    public func compress(
        _ input: Data,
        maximumOutputLength: Int = ZlibCodec.defaultMaximumOutputLength
    ) throws -> Data {
        guard !input.isEmpty, maximumOutputLength > 0,
              input.count <= Int(uInt.max) else {
            throw ZlibCodecError.invalidStream
        }
        let bound = deflateBound(&stream, uLong(input.count))
        guard bound <= uLong(maximumOutputLength), bound <= uLong(Int.max) else {
            throw ZlibCodecError.outputTooLarge
        }
        let startingTotal = stream.total_out
        var output = Data(count: Int(bound))
        let status = input.withUnsafeBytes { inputBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                guard let inputAddress = inputBuffer.bindMemory(to: Bytef.self).baseAddress,
                      let outputAddress = outputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                    return Int32(Z_STREAM_ERROR)
                }
                stream.next_in = UnsafeMutablePointer(mutating: inputAddress)
                stream.avail_in = uInt(inputBuffer.count)
                stream.next_out = outputAddress
                stream.avail_out = uInt(outputBuffer.count)
                return deflate(&stream, Z_SYNC_FLUSH)
            }
        }
        guard status == Z_OK, stream.avail_in == 0 else {
            throw status == Z_BUF_ERROR || stream.avail_out == 0
                ? ZlibCodecError.outputTooLarge
                : ZlibCodecError.invalidStream
        }
        let produced = stream.total_out - startingTotal
        guard produced <= UInt(maximumOutputLength), produced <= UInt(Int.max) else {
            throw ZlibCodecError.outputTooLarge
        }
        output.count = Int(produced)
        return output
    }
}

/// Stateful decoder paired with `ZlibSyncFlushCompressor`. A single instance
/// must consume every compressed segment in wire order.
public final class ZlibSyncFlushDecompressor {
    private var stream = z_stream()

    public init() throws {
        guard inflateInit_(
            &stream,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            throw ZlibCodecError.invalidStream
        }
    }

    deinit {
        inflateEnd(&stream)
    }

    public func decompress(
        _ input: Data,
        expectedSize: Int,
        maximumOutputLength: Int = ZlibCodec.defaultMaximumOutputLength
    ) throws -> Data {
        guard !input.isEmpty,
              input.count <= Int(uInt.max),
              (1...maximumOutputLength).contains(expectedSize),
              expectedSize < Int.max else {
            throw ZlibCodecError.invalidStream
        }
        var output = Data(count: expectedSize + 1)
        let status = input.withUnsafeBytes { inputBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                guard let inputAddress = inputBuffer.bindMemory(to: Bytef.self).baseAddress,
                      let outputAddress = outputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                    return Int32(Z_STREAM_ERROR)
                }
                stream.next_in = UnsafeMutablePointer(mutating: inputAddress)
                stream.avail_in = uInt(inputBuffer.count)
                stream.next_out = outputAddress
                stream.avail_out = uInt(outputBuffer.count)
                return inflate(&stream, Z_SYNC_FLUSH)
            }
        }
        let produced = output.count - Int(stream.avail_out)
        guard status == Z_OK, stream.avail_in == 0, produced == expectedSize else {
            throw produced > expectedSize ? ZlibCodecError.outputTooLarge : ZlibCodecError.invalidStream
        }
        output.count = produced
        return output
    }
}

public enum ZlibCodecError: Error, Equatable {
    case invalidStream
    case outputTooLarge
}
