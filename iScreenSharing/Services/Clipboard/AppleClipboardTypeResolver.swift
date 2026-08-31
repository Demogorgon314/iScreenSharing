import CoreServices
import Foundation
import struct ScreenSharingProtocol.AppleClipboardFlavor
import struct ScreenSharingProtocol.AppleClipboardTypeAlias

struct AppleClipboardTypeResolver: Sendable {
    typealias IsDeclared = @Sendable (String) -> Bool
    typealias PreferredTag = @Sendable (_ type: String, _ tagClass: String) -> String?
    typealias PreferredIdentifier = @Sendable (_ tagClass: String, _ tag: String) -> String?

    private let isDeclared: IsDeclared
    private let preferredTag: PreferredTag
    private let preferredIdentifier: PreferredIdentifier

    init(
        isDeclared: @escaping IsDeclared,
        preferredTag: @escaping PreferredTag,
        preferredIdentifier: @escaping PreferredIdentifier
    ) {
        self.isDeclared = isDeclared
        self.preferredTag = preferredTag
        self.preferredIdentifier = preferredIdentifier
    }

    func aliases(for type: String) -> [AppleClipboardTypeAlias] {
        Self.tagClasses.compactMap { tagClass in
            guard let tag = preferredTag(type, tagClass) else { return nil }
            return AppleClipboardTypeAlias(
                tagClass: tagClass,
                preferredTag: tag
            )
        }
    }

    func identifiers(for flavor: AppleClipboardFlavor) -> [String] {
        if !flavor.type.isEmpty, isDeclared(flavor.type) {
            return [flavor.type]
        }

        let tags = flavor.aliases.reduce(into: [String: String]()) { tags, alias in
            tags[alias.tagClass] = alias.preferredTag
        }
        var identifiers = [String]()
        for tagClass in Self.tagClasses {
            guard let tag = tags[tagClass],
                  let identifier = preferredIdentifier(tagClass, tag),
                  !identifiers.contains(identifier) else {
                continue
            }
            identifiers.append(identifier)
        }
        if identifiers.isEmpty, !flavor.type.isEmpty {
            identifiers.append(flavor.type)
        }
        return identifiers
    }

    static let system = AppleClipboardTypeResolver(
        isDeclared: { type in
            UTTypeIsDeclared(type as CFString)
        },
        preferredTag: { type, tagClass in
            UTTypeCopyPreferredTagWithClass(
                type as CFString,
                tagClass as CFString
            )?.takeRetainedValue() as String?
        },
        preferredIdentifier: { tagClass, tag in
            UTTypeCreatePreferredIdentifierForTag(
                tagClass as CFString,
                tag as CFString,
                nil
            )?.takeRetainedValue() as String?
        }
    )

    // Screen Sharing uses the legacy LaunchServices tag classes in this
    // priority order when reconstructing pasteboard flavors. The APIs are
    // deprecated but remain the only exact source for NSPasteboard and OSType
    // aliases used by the native wire format.
    private static let tagClasses = [
        "com.apple.ostype",
        "com.apple.nspboard-type",
        "public.filename-extension",
        "public.mime-type",
    ]
}
