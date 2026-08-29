import Foundation
import ScreenSharingProtocol

extension ScreenSharingProtocol.AppleMediaOffer {
    static func create(
        audioEnabled: Bool = true,
        randomUInt32: () throws -> UInt32 = { try Cryptography.randomUInt32() },
        timestamp: () -> UInt64 = {
            UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        },
        uuid: () -> UUID = UUID.init
    ) throws -> ScreenSharingProtocol.AppleMediaOffers {
        try create(
            audioEnabled: audioEnabled,
            randomUInt32: randomUInt32,
            timestamp: timestamp,
            uuid: uuid,
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }
}
