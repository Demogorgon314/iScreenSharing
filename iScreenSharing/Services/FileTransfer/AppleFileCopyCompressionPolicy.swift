import Foundation

struct AppleFileCopyCompressionPolicy {
    private static let uncompressedExtensions: Set<String> = [
        "cpio", "gz", "bz2", "zip", "z", "lz", "lzo", "rz", "Z", "7z",
        "ace", "rar", "arc", "cab", "cpt", "sit", "tgz", "aac", "mp3", "mp2",
        "mpa", "avi", "h264", "mov", "mp4", "m4v", "mjpg", "mkv", "mob",
        "moov", "mpg2",
    ]

    private let startTick: UInt32
    private var compressedBlockCount: UInt64 = 0
    private var compressedInputBytes: UInt64 = 0
    private var compressionSavings: UInt64 = 0
    private var savingsAreTooSmall = false

    init(startTick: UInt32) {
        self.startTick = startTick
    }

    mutating func shouldCompress(
        fileName: String,
        pendingBytes: UInt64,
        totalBytesSent: UInt64,
        currentTick: UInt32
    ) -> Bool {
        guard !savingsAreTooSmall,
              !Self.uncompressedExtensions.contains(
                  URL(fileURLWithPath: fileName).pathExtension
              ),
              pendingBytes > 0 else {
            return false
        }
        let elapsedTicks = currentTick &- startTick
        guard elapsedTicks >= 9 else { return false }

        let (sixTimesSent, overflow) = totalBytesSent.multipliedReportingOverflow(by: 6)
        let rateThreshold = (overflow ? UInt64.max : sixTimesSent / UInt64(elapsedTicks)) >> 1
        guard pendingBytes > rateThreshold else { return false }

        if compressedBlockCount >= 6,
           compressionSavings <= compressedInputBytes >> 3 {
            savingsAreTooSmall = true
            return false
        }
        return true
    }

    mutating func recordCompressedBlock(inputBytes: Int, outputBytes: Int) {
        guard inputBytes > 0, outputBytes > 0 else { return }
        compressedBlockCount &+= 1
        compressedInputBytes &+= UInt64(inputBytes)
        if outputBytes < inputBytes {
            compressionSavings &+= UInt64(inputBytes - outputBytes)
        }
    }
}
