import CommonCrypto
import Foundation
import Security

enum Cryptography {
    static func randomBytes(count: Int) throws -> Data {
        guard count >= 0 else { throw CryptographyError.randomGenerationFailed }
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw CryptographyError.randomGenerationFailed
        }
        return data
    }

    static func encryptAESECB(_ plaintext: Data, key: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128,
              plaintext.count.isMultiple(of: kCCBlockSizeAES128) else {
            throw CryptographyError.invalidAESInput
        }

        let outputCapacity = plaintext.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            plaintext.withUnsafeBytes { plaintextBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress,
                        key.count,
                        nil,
                        plaintextBytes.baseAddress,
                        plaintext.count,
                        outputBytes.baseAddress,
                        outputCapacity,
                        &outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw CryptographyError.aesEncryptionFailed(status)
        }
        output.removeSubrange(outputLength..<output.count)
        return output
    }

    static func makeRSAPublicKey(subjectPublicKeyInfo: Data) throws -> SecKey {
        let pkcs1 = try DERSubjectPublicKeyInfo.extractRSAPublicKey(from: subjectPublicKeyInfo)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            throw CryptographyError.invalidRSAPublicKey(error?.takeRetainedValue().localizedDescription)
        }
        return key
    }

    static func encryptRSA(_ plaintext: Data, publicKey: SecKey) throws -> Data {
        guard SecKeyIsAlgorithmSupported(publicKey, .encrypt, .rsaEncryptionPKCS1) else {
            throw CryptographyError.unsupportedRSAAlgorithm
        }
        var error: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(
            publicKey,
            .rsaEncryptionPKCS1,
            plaintext as CFData,
            &error
        ) else {
            throw CryptographyError.rsaEncryptionFailed(error?.takeRetainedValue().localizedDescription)
        }
        return encrypted as Data
    }
}

private enum DERSubjectPublicKeyInfo {
    static func extractRSAPublicKey(from data: Data) throws -> Data {
        var outer = DERReader(data: data)
        let sequence = try outer.read(tag: 0x30)
        guard outer.isAtEnd else { throw CryptographyError.invalidRSAPublicKey(nil) }

        var fields = DERReader(data: sequence)
        _ = try fields.read(tag: 0x30)
        let bitString = try fields.read(tag: 0x03)
        guard fields.isAtEnd, bitString.first == 0, bitString.count > 1 else {
            throw CryptographyError.invalidRSAPublicKey(nil)
        }
        return bitString.dropFirst()
    }
}

private struct DERReader {
    let data: Data
    var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func read(tag expectedTag: UInt8) throws -> Data {
        guard offset < data.count, data[offset] == expectedTag else {
            throw CryptographyError.invalidRSAPublicKey(nil)
        }
        offset += 1
        let length = try readLength()
        guard length >= 0, data.count - offset >= length else {
            throw CryptographyError.invalidRSAPublicKey(nil)
        }
        defer { offset += length }
        return data.subdata(in: offset..<(offset + length))
    }

    private mutating func readLength() throws -> Int {
        guard offset < data.count else { throw CryptographyError.invalidRSAPublicKey(nil) }
        let first = data[offset]
        offset += 1
        if first & 0x80 == 0 { return Int(first) }

        let byteCount = Int(first & 0x7f)
        guard byteCount > 0, byteCount <= 4, data.count - offset >= byteCount else {
            throw CryptographyError.invalidRSAPublicKey(nil)
        }
        var length = 0
        for _ in 0..<byteCount {
            length = (length << 8) | Int(data[offset])
            offset += 1
        }
        return length
    }
}

enum CryptographyError: LocalizedError {
    case randomGenerationFailed
    case invalidAESInput
    case aesEncryptionFailed(CCCryptorStatus)
    case invalidRSAPublicKey(String?)
    case unsupportedRSAAlgorithm
    case rsaEncryptionFailed(String?)

    var errorDescription: String? {
        switch self {
        case .randomGenerationFailed:
            "Couldn’t generate secure random data."
        case .invalidAESInput, .aesEncryptionFailed:
            "Couldn’t encrypt the Screen Sharing credentials."
        case .invalidRSAPublicKey:
            "The Mac returned an RSA key that couldn’t be used."
        case .unsupportedRSAAlgorithm:
            "The Mac’s RSA key uses an unsupported encryption algorithm."
        case .rsaEncryptionFailed:
            "Couldn’t encrypt the session key for the Mac."
        }
    }
}
