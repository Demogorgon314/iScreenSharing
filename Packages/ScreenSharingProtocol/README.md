# ScreenSharingProtocol

`ScreenSharingProtocol` is a macOS-first Swift library for deterministic wire
formats used by RFB and Apple's Screen Sharing high-performance mode. It is the
reusable protocol core extracted from iScreenSharing.

The current private-protocol baseline is macOS 15.7.7 (24G720). Behavior on
other releases must be verified rather than inferred from this implementation.

## Scope

The package owns:

- RFB version, security-type, and ServerInit parsing, plus fixed Standard-mode
  client messages and pixel-format wire values
- Apple RSA1 authentication payloads
- Apple control, display, media-negotiation, clipboard, file-transfer, cursor,
  keyboard-source, and rekey wire values
- chained encrypted control records and AES-ECB encrypted input messages
- Apple SRTP decryption, SRTCP protection, RTCP feedback, RTP extension values,
  HEVC NAL reassembly, and rate-control serialization

The package deliberately does not own sockets, Network.framework transports,
Direct or Tailscale routing, authentication/session lifecycle, ordered network
writes, media queues, decoders, rendering, AppKit input, Pasteboard access, or
Finder helper processes. Those are application and platform responsibilities.

This is a wire-protocol library, not a complete Screen Sharing Session SDK. It
currently supports macOS 15 and does not promise Linux, iOS, or older macOS
compatibility.

## Adding the package

The package is currently consumed as a local Swift package. Add the
`Packages/ScreenSharingProtocol` directory to an Xcode workspace, or reference
its path from another package during development:

```swift
dependencies: [
    .package(path: "../iScreenSharing/Packages/ScreenSharingProtocol"),
]
```

Then add `ScreenSharingProtocol` to the target dependencies and import it:

```swift
import Foundation
import ScreenSharingProtocol

let version = try RFBProtocol.parseVersion(Data("RFB 003.889\n".utf8))
guard version == RFBVersion(major: 3, minor: 889) else {
    throw RFBProtocolError.invalidVersionBanner
}
```

Encrypted records are stateful. Keep one `AppleEncryptedRecordLayer` per
authenticated connection and serialize transport writes in the consuming app:

```swift
let keys = try AppleRecordKeys(
    key: negotiatedContentKey,
    initializationVector: negotiatedInitializationVector
)
let records = AppleEncryptedRecordLayer(keys: keys)
let ciphertext = try records.encrypt(AppleRFBMessages.controlMode(observing: false))
try await orderedTransport.send(ciphertext)
```

Do not share an encrypted record layer between connections or send its output
through unordered tasks. SRTP/SRTCP instances likewise retain per-stream
protocol state; the consumer remains responsible for preserving packet order
at the media-processing boundary.

## Build and test

The package has no dependency on the app target or the embedded Tailscale
submodule:

```sh
swift test
swift build -c release
```

Protocol changes should include deterministic golden vectors and malformed,
truncated, oversized, wraparound, or authentication-failure coverage as
applicable. Never log negotiated keys, decrypted clipboard contents, or private
user data.

## Documentation

Open the package in Xcode and use **Product > Build Documentation**, or build
the `ScreenSharingProtocol` DocC catalog from the command line with Xcode's
documentation build action.

## Status

No public semantic-versioned release or compatibility guarantee has been
declared yet. Consumers should pin a known commit until the project's license,
initial version, and API change policy are published.
