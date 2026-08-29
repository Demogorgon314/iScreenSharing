import Foundation
import XCTest
@testable import ScreenSharingProtocol

final class AppleProtocolAESTests: XCTestCase {
    func testECBMatchesNISTKnownAnswerAndDecrypts() throws {
        let key = try XCTUnwrap(Data(hex: """
            000102030405060708090a0b0c0d0e0f
            101112131415161718191a1b1c1d1e1f
            """))
        let plaintext = try XCTUnwrap(Data(hex: "00112233445566778899aabbccddeeff"))
        let ciphertext = try XCTUnwrap(Data(hex: "8ea2b7ca516745bfeafc49904b496089"))

        XCTAssertEqual(try AppleProtocolAES.encryptECB(plaintext, key: key), ciphertext)
        XCTAssertEqual(try AppleProtocolAES.decryptECB(ciphertext, key: key), plaintext)
    }

    func testCBCMatchesNISTKnownAnswerAndDecrypts() throws {
        let key = try XCTUnwrap(Data(hex: "2b7e151628aed2a6abf7158809cf4f3c"))
        let vector = try XCTUnwrap(Data(hex: "000102030405060708090a0b0c0d0e0f"))
        let plaintext = try XCTUnwrap(Data(hex: """
            6bc1bee22e409f96e93d7e117393172a
            ae2d8a571e03ac9c9eb76fac45af8e51
            30c81c46a35ce411e5fbc1191a0a52ef
            f69f2445df4f9b17ad2b417be66c3710
            """))
        let ciphertext = try XCTUnwrap(Data(hex: """
            7649abac8119b246cee98e9b12e9197d
            5086cb9b507219ee95db113a917678b2
            73bed6b8e3c1743b7116e69e22229516
            3ff1caa1681fac09120eca307586e1a7
            """))

        XCTAssertEqual(
            try AppleProtocolAES.encryptCBC(plaintext, key: key, initializationVector: vector),
            ciphertext
        )
        XCTAssertEqual(
            try AppleProtocolAES.decryptCBC(ciphertext, key: key, initializationVector: vector),
            plaintext
        )
    }

    func testCTRMatchesNISTKnownAnswerAndRoundTrips() throws {
        let key = try XCTUnwrap(Data(hex: """
            603deb1015ca71be2b73aef0857d7781
            1f352c073b6108d72d9810a30914dff4
            """))
        let vector = try XCTUnwrap(Data(hex: "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"))
        let plaintext = try XCTUnwrap(Data(hex: """
            6bc1bee22e409f96e93d7e117393172a
            ae2d8a571e03ac9c9eb76fac45af8e51
            30c81c46a35ce411e5fbc1191a0a52ef
            f69f2445df4f9b17ad2b417be66c3710
            """))
        let ciphertext = try XCTUnwrap(Data(hex: """
            601ec313775789a5b7a7f504bbf3d228
            f443e3ca4d62b59aca84e990cacaf5c5
            2b0930daa23de94ce87017ba2d84988d
            dfc9c58db67aada613c2dd08457941a6
            """))

        XCTAssertEqual(
            try AppleProtocolAES.cryptCTR(plaintext, key: key, initializationVector: vector),
            ciphertext
        )
        XCTAssertEqual(
            try AppleProtocolAES.cryptCTR(ciphertext, key: key, initializationVector: vector),
            plaintext
        )
    }

    func testRejectsInvalidKeysVectorsAndBlockLengths() throws {
        let block = Data(repeating: 0, count: 16)

        XCTAssertThrowsError(try AppleProtocolAES.encryptECB(
            block.dropLast(),
            key: block
        )) {
            XCTAssertEqual($0 as? AppleProtocolAESError, .invalidInput)
        }
        XCTAssertThrowsError(try AppleProtocolAES.encryptCBC(
            block,
            key: Data(repeating: 0, count: 32),
            initializationVector: block
        )) {
            XCTAssertEqual($0 as? AppleProtocolAESError, .invalidInput)
        }
        XCTAssertThrowsError(try AppleProtocolAES.cryptCTR(
            block,
            key: block,
            initializationVector: block.dropLast()
        )) {
            XCTAssertEqual($0 as? AppleProtocolAESError, .invalidInput)
        }
    }

    func testEmptyInputContracts() throws {
        let key = Data(repeating: 0, count: 16)
        let vector = Data(repeating: 0, count: 16)

        XCTAssertEqual(try AppleProtocolAES.encryptECB(Data(), key: key), Data())
        XCTAssertEqual(
            try AppleProtocolAES.cryptCTR(Data(), key: key, initializationVector: vector),
            Data()
        )
        XCTAssertThrowsError(try AppleProtocolAES.encryptCBC(
            Data(),
            key: key,
            initializationVector: vector
        )) {
            XCTAssertEqual($0 as? AppleProtocolAESError, .invalidInput)
        }
    }
}

private extension Data {
    init?(hex: String) {
        let hex = hex.filter { !$0.isWhitespace }
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
