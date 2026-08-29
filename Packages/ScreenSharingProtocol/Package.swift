// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ScreenSharingProtocol",
    platforms: [
        .macOS("15.0"),
    ],
    products: [
        .library(
            name: "ScreenSharingProtocol",
            targets: ["ScreenSharingProtocol"]
        ),
    ],
    targets: [
        .target(name: "ScreenSharingProtocol"),
        .testTarget(
            name: "ScreenSharingProtocolTests",
            dependencies: ["ScreenSharingProtocol"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
