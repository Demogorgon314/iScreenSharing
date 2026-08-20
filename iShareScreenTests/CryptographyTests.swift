import Security
import XCTest
@testable import iShareScreen

final class CryptographyTests: XCTestCase {
    func testAESECBMatchesNISTKnownAnswer() throws {
        let key = try XCTUnwrap(Data(hex: "000102030405060708090a0b0c0d0e0f"))
        let plaintext = try XCTUnwrap(Data(hex: "00112233445566778899aabbccddeeff"))

        let encrypted = try Cryptography.encryptAESECB(plaintext, key: key)

        XCTAssertEqual(encrypted, Data(hex: "69c4e0d86a7b0430d8cdb78070b4c55a"))
    }

    func testCreatesSPKIPublicKeyAndEncryptsRSA2048Block() throws {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
        ]
        var generationError: Unmanaged<CFError>?
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, &generationError))
        let generatedPublicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        var exportError: Unmanaged<CFError>?
        let pkcs1 = try XCTUnwrap(SecKeyCopyExternalRepresentation(generatedPublicKey, &exportError) as Data?)
        let spki = DERFixture.rsaSubjectPublicKeyInfo(pkcs1: pkcs1)

        let parsedPublicKey = try Cryptography.makeRSAPublicKey(subjectPublicKeyInfo: spki)
        let encrypted = try Cryptography.encryptRSA(Data(repeating: 0x42, count: 16), publicKey: parsedPublicKey)

        XCTAssertEqual(SecKeyGetBlockSize(parsedPublicKey), 256)
        XCTAssertEqual(encrypted.count, 256)
    }

    func testRejectsInvalidAESInputsAndMalformedDER() {
        XCTAssertThrowsError(
            try Cryptography.encryptAESECB(Data(repeating: 0, count: 15), key: Data(repeating: 0, count: 16))
        )
        XCTAssertThrowsError(
            try Cryptography.makeRSAPublicKey(subjectPublicKeyInfo: Data([0x30, 0x01, 0x00]))
        )
    }
}

private enum DERFixture {
    static func rsaSubjectPublicKeyInfo(pkcs1: Data) -> Data {
        let rsaEncryptionAlgorithm = Data([
            0x30, 0x0d,
            0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
            0x05, 0x00,
        ])
        let bitString = der(tag: 0x03, content: Data([0]) + pkcs1)
        return der(tag: 0x30, content: rsaEncryptionAlgorithm + bitString)
    }

    private static func der(tag: UInt8, content: Data) -> Data {
        Data([tag]) + encodedLength(content.count) + content
    }

    private static func encodedLength(_ length: Int) -> Data {
        if length < 128 { return Data([UInt8(length)]) }
        var value = length
        var bytes = [UInt8]()
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        self.init()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            append(byte)
            index = next
        }
    }
}

