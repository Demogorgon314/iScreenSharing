// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ScreenSharingProtocolPublicAPISmoke",
    platforms: [
        .macOS("15.0"),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "PublicAPISmoke",
            dependencies: [
                .product(name: "ScreenSharingProtocol", package: "ScreenSharingProtocol"),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
