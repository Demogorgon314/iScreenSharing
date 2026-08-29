import ScreenSharingProtocol

extension ScreenSharingProtocol.AppleMediaKeys {
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
}
