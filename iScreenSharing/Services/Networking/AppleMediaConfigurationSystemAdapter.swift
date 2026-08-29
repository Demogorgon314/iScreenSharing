import Foundation
import ScreenSharingProtocol

extension ScreenSharingProtocol.AppleMediaConfiguration {
    static func message(
        audioOffer: Data,
        videoOffer: Data,
        secondaryVideoOffer: Data? = nil,
        keys: AppleMediaKeys
    ) throws -> Data {
        try message(
            audioOffer: audioOffer,
            videoOffer: videoOffer,
            secondaryVideoOffer: secondaryVideoOffer,
            keys: keys,
            callID: UUID()
        )
    }
}
