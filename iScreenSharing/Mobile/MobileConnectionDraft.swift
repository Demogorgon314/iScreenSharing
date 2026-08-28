import Foundation

struct MobileConnectionDraft: Equatable {
    var address = ""

    func endpoint() throws -> ConnectionEndpoint {
        try ConnectionEndpoint(address)
    }
}
