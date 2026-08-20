import Foundation

struct ScreenSharingCredentials: Equatable, Sendable {
    let username: String
    let password: String

    init(username: String, password: String) throws {
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUsername.isEmpty else {
            throw ScreenSharingCredentialsError.missingUsername
        }
        guard !password.isEmpty else {
            throw ScreenSharingCredentialsError.missingPassword
        }
        guard normalizedUsername.utf8.count < AppleRSA1.credentialFieldLength,
              password.utf8.count < AppleRSA1.credentialFieldLength else {
            throw ScreenSharingCredentialsError.credentialTooLong
        }
        self.username = normalizedUsername
        self.password = password
    }
}

enum ScreenSharingCredentialsError: LocalizedError, Equatable {
    case missingUsername
    case missingPassword
    case credentialTooLong

    var errorDescription: String? {
        switch self {
        case .missingUsername:
            "Enter the account name for the remote Mac."
        case .missingPassword:
            "Enter the password for the remote Mac."
        case .credentialTooLong:
            "The account name and password must each be shorter than 64 UTF-8 bytes."
        }
    }
}
