import Foundation

struct AppleCursorImage: Equatable, Sendable {
    let width: Int
    let height: Int
    let hotspotX: Int
    let hotspotY: Int
    let rgba: Data
}

enum AppleCursorUpdate: Equatable, Sendable {
    case store(id: UInt32, image: AppleCursorImage)
    case select(id: UInt32)
}
