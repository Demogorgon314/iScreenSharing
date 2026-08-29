import Foundation

public struct AppleCursorImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let hotspotX: Int
    public let hotspotY: Int
    public let rgba: Data

    public init(width: Int, height: Int, hotspotX: Int, hotspotY: Int, rgba: Data) {
        self.width = width
        self.height = height
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.rgba = rgba
    }
}

public enum AppleCursorUpdate: Equatable, Sendable {
    case store(id: UInt32, image: AppleCursorImage)
    case select(id: UInt32)
}
