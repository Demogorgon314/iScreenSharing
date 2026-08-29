import Foundation
import ScreenSharingProtocol

let version = try RFBProtocol.parseVersion(Data("RFB 003.889\n".utf8))
precondition(version == RFBVersion(major: 3, minor: 889))

let recordKeys = try AppleRecordKeys(
    key: Data(repeating: 0, count: 16),
    initializationVector: Data(repeating: 0, count: 16)
)
let recordLayer = AppleEncryptedRecordLayer(keys: recordKeys)
let pointerMessage = try recordLayer.encryptPointerEvent(buttons: 0, x: 1, y: 2)
precondition(pointerMessage.count == 18)

let mediaKeyBlob = Data(repeating: 0, count: AppleMediaKeys.blobLength)
_ = try AppleSRTPDecryptor(keyBlob: mediaKeyBlob)
_ = try AppleSRTCPEncryptor(keyBlob: mediaKeyBlob)
