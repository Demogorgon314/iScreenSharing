import Foundation

enum ConnectionLocationDocument {
    static let fileExtension = "vncloc"

    static func data(for endpoint: ConnectionEndpoint) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: ["URL": endpoint.url.absoluteString],
            format: .xml,
            options: 0
        )
    }

    static func endpoint(from data: Data) throws -> ConnectionEndpoint {
        guard let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = propertyList as? [String: Any],
              let urlString = dictionary["URL"] as? String else {
            throw ConnectionLocationDocumentError.invalidDocument
        }
        do {
            return try ConnectionEndpoint(urlString)
        } catch {
            throw ConnectionLocationDocumentError.invalidAddress
        }
    }
}

enum ConnectionLocationDocumentError: LocalizedError, Equatable {
    case invalidDocument
    case invalidAddress

    var errorDescription: String? {
        switch self {
        case .invalidDocument: "The VNC location document is invalid."
        case .invalidAddress: "The VNC location document does not contain a valid address."
        }
    }
}
