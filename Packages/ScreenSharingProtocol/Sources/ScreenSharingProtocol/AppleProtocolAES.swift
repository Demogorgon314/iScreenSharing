import CommonCrypto
import Foundation

enum AppleProtocolAES {
    static func encryptECB(_ plaintext: Data, key: Data) throws -> Data {
        try cryptECB(plaintext, key: key, operation: CCOperation(kCCEncrypt))
    }

    static func decryptECB(_ ciphertext: Data, key: Data) throws -> Data {
        try cryptECB(ciphertext, key: key, operation: CCOperation(kCCDecrypt))
    }

    static func cryptCTR(_ input: Data, key: Data, initializationVector: Data) throws -> Data {
        guard validKeyLengths.contains(key.count), initializationVector.count == blockSize else {
            throw AppleProtocolAESError.invalidInput
        }
        var cryptor: CCCryptorRef?
        let creationStatus = key.withUnsafeBytes { keyBytes in
            initializationVector.withUnsafeBytes { vectorBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    vectorBytes.baseAddress,
                    keyBytes.baseAddress,
                    key.count,
                    nil,
                    0,
                    0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor
                )
            }
        }
        guard creationStatus == kCCSuccess, let cryptor else {
            throw AppleProtocolAESError.operationFailed(creationStatus)
        }
        defer { CCCryptorRelease(cryptor) }

        let outputCapacity = input.count + blockSize
        var output = Data(count: outputCapacity)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                CCCryptorUpdate(
                    cryptor,
                    inputBytes.baseAddress,
                    input.count,
                    outputBytes.baseAddress,
                    outputCapacity,
                    &outputLength
                )
            }
        }
        guard status == kCCSuccess else {
            throw AppleProtocolAESError.operationFailed(status)
        }
        output.removeSubrange(outputLength..<output.count)
        return output
    }

    static func encryptCBC(
        _ plaintext: Data,
        key: Data,
        initializationVector: Data
    ) throws -> Data {
        try cryptCBC(
            plaintext,
            key: key,
            initializationVector: initializationVector,
            operation: CCOperation(kCCEncrypt)
        )
    }

    static func decryptCBC(
        _ ciphertext: Data,
        key: Data,
        initializationVector: Data
    ) throws -> Data {
        try cryptCBC(
            ciphertext,
            key: key,
            initializationVector: initializationVector,
            operation: CCOperation(kCCDecrypt)
        )
    }

    private static let blockSize = kCCBlockSizeAES128
    private static let validKeyLengths = [kCCKeySizeAES128, kCCKeySizeAES192, kCCKeySizeAES256]

    private static func cryptECB(
        _ input: Data,
        key: Data,
        operation: CCOperation
    ) throws -> Data {
        guard validKeyLengths.contains(key.count), input.count.isMultiple(of: blockSize) else {
            throw AppleProtocolAESError.invalidInput
        }
        return try crypt(
            input,
            key: key,
            initializationVector: nil,
            operation: operation,
            options: CCOptions(kCCOptionECBMode)
        )
    }

    private static func cryptCBC(
        _ input: Data,
        key: Data,
        initializationVector: Data,
        operation: CCOperation
    ) throws -> Data {
        guard key.count == kCCKeySizeAES128,
              initializationVector.count == blockSize,
              !input.isEmpty,
              input.count.isMultiple(of: blockSize) else {
            throw AppleProtocolAESError.invalidInput
        }
        return try crypt(
            input,
            key: key,
            initializationVector: initializationVector,
            operation: operation,
            options: 0
        )
    }

    private static func crypt(
        _ input: Data,
        key: Data,
        initializationVector: Data?,
        operation: CCOperation,
        options: CCOptions
    ) throws -> Data {
        let outputCapacity = input.count + blockSize
        var output = Data(count: outputCapacity)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    guard let initializationVector else {
                        return CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            options,
                            keyBytes.baseAddress,
                            key.count,
                            nil,
                            inputBytes.baseAddress,
                            input.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                    return initializationVector.withUnsafeBytes { vectorBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            options,
                            keyBytes.baseAddress,
                            key.count,
                            vectorBytes.baseAddress,
                            inputBytes.baseAddress,
                            input.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw AppleProtocolAESError.operationFailed(status)
        }
        output.removeSubrange(outputLength..<output.count)
        return output
    }
}

enum AppleProtocolAESError: Error, Equatable {
    case invalidInput
    case operationFailed(CCCryptorStatus)
}
