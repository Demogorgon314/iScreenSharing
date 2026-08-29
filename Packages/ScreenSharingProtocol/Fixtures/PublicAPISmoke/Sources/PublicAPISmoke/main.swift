import Foundation
import ScreenSharingProtocol

let version = try RFBProtocol.parseVersion(Data("RFB 003.889\n".utf8))
precondition(version == RFBVersion(major: 3, minor: 889))

let standardPixelFormat = StandardRFBPixelFormat.standard
precondition(StandardRFBMessages.setPixelFormat(standardPixelFormat).count == 20)
precondition(StandardRFBMessages.clientInit == Data([1]))
_ = try StandardRFBMessages.setEncodings([
    StandardRFBMessages.subZlibHalftoneEncoding,
    StandardRFBMessages.subZlib16GrayEncoding,
    StandardRFBMessages.subZlibThousandsEncoding,
    StandardRFBMessages.copyRectangleEncoding,
    StandardRFBMessages.zlibEncoding,
    StandardRFBMessages.rawEncoding,
    StandardRFBMessages.hextileEncoding,
    StandardRFBMessages.desktopSizeEncoding,
])
precondition(StandardRFBMessages.keyEvent(isDown: true, symbol: 0x41).count == 8)
precondition(StandardRFBMessages.pointerEvent(buttons: 1, x: 2, y: 3).count == 6)

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
