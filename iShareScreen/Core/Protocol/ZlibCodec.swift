import Compression
import Foundation

enum ZlibCodec {
    private static let maximumOutputLength = 16 * 1_024 * 1_024

    static func compress(_ input: Data) throws -> Data {
        let deflate = try transform(
            input,
            initialCapacity: max(256, input.count * 2),
            function: compression_encode_buffer
        )
        var output = Data([0x78, 0x9c])
        output.append(deflate)
        output.appendUInt32BE(adler32(input))
        return output
    }

    static func decompress(_ input: Data) throws -> Data {
        guard input.count >= 6, hasValidHeader(input), input[1] & 0x20 == 0 else {
            throw ZlibCodecError.invalidStream
        }
        let deflate = input.subdata(in: 2..<(input.count - 4))
        let output = try transform(
            deflate,
            initialCapacity: max(4_096, input.count * 4),
            function: compression_decode_buffer
        )
        guard adler32(output) == (try input.uint32BE(at: input.count - 4)) else {
            throw ZlibCodecError.invalidStream
        }
        return output
    }

    static func decompressSyncFlush(_ input: Data, expectedSize: Int) throws -> Data {
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
                let status = compression_stream_process(stream, 0)
                let produced = chunkSize - stream.pointee.dst_size
                if produced > 0 { output.append(destination, count: produced) }
                guard output.count <= maximumOutputLength else { throw ZlibCodecError.outputTooLarge }
                if status == COMPRESSION_STATUS_END || stream.pointee.src_size == 0 { break }
                guard status == COMPRESSION_STATUS_OK else { throw ZlibCodecError.invalidStream }
            }
        }
        return output
    }

    private static func hasValidHeader(_ input: Data) -> Bool {
        input[0] & 0x0f == 8 && (Int(input[0]) << 8 | Int(input[1])).isMultiple(of: 31)
    }

    private static func transform(
        _ input: Data,
        initialCapacity: Int,
        function: (UnsafeMutablePointer<UInt8>, Int, UnsafePointer<UInt8>, Int, UnsafeMutableRawPointer?, compression_algorithm) -> Int
    ) throws -> Data {
        guard !input.isEmpty else { throw ZlibCodecError.invalidStream }
        var capacity = initialCapacity
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
            capacity *= 2
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

enum ZlibCodecError: Error, Equatable {
    case invalidStream
    case outputTooLarge
}
