import Foundation

/// Model families verified against macOS 26.6.1 CoreTypes device-model tags.
/// Unknown future identifiers intentionally retain the generic display icon.
enum MobileMacIcon {
    static func symbol(for modelIdentifier: String?) -> String {
        let model = modelIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if model.hasPrefix("MacBook") { return "laptopcomputer" }
        if model.hasPrefix("iMac") { return "desktopcomputer" }
        if model.hasPrefix("Macmini") { return "macmini" }
        if model == "MacPro6,1" { return "macpro.gen2" }
        if model.hasPrefix("MacPro") { return model == "MacPro7,1" ? "macpro.gen3" : "macpro.gen1" }
        switch model {
        case "Mac13,1", "Mac13,2", "Mac14,13", "Mac14,14", "Mac15,14", "Mac16,9":
            return "macstudio"
        case "Mac14,3", "Mac14,12", "Mac16,10", "Mac16,11":
            return "macmini"
        case "Mac14,8":
            return "macpro.gen3"
        case "Mac14,2", "Mac14,5", "Mac14,6", "Mac14,7", "Mac14,9", "Mac14,10", "Mac14,15",
             "Mac15,3", "Mac15,6", "Mac15,7", "Mac15,8", "Mac15,9", "Mac15,10", "Mac15,11", "Mac15,12", "Mac15,13",
             "Mac16,1", "Mac16,5", "Mac16,6", "Mac16,7", "Mac16,8", "Mac16,12", "Mac16,13",
             "Mac17,2", "Mac17,3", "Mac17,4", "Mac17,5", "Mac17,6", "Mac17,7", "Mac17,8", "Mac17,9":
            return "laptopcomputer"
        default:
            return "desktopcomputer"
        }
    }
}
