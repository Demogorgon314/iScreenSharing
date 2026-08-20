# iShareScreenSwift

A native macOS client for Apple's Screen Sharing protocol, implemented in Swift.

## Architecture

- `App`: SwiftUI application lifecycle, commands, and scene composition
- `Features`: feature-owned views, coordinators, and observable presentation state
- `Core/Models`: domain values with no UI, transport, or framework dependencies
- `Core/Protocol`: deterministic Apple RFB 3.889 wire-format parsing and encoding
- `Services/Networking`: Network.framework transports and control-channel services
- `Services/Media`: RTP processing plus VideoToolbox and Core Audio adapters
- `Services/Session`: the authenticated-session aggregate and resource lifecycle
- `Services/Clipboard` and `Services/Security`: focused macOS platform adapters

Dependencies point inward: views coordinate services through domain types, while
protocol code never imports UI or networking frameworks. SwiftUI owns window and
toolbar state; AppKit is isolated behind `NSViewRepresentable` for native input
and `AVSampleBufferDisplayLayer` rendering. The session aggregate owns the
lifetime of its TCP, UDP, media, input, and clipboard resources so closing a
window tears down one connection predictably.

Mutable state has one explicit owner. UI-facing state is published on the main
actor, ordered control writes use actors, and media decode/playback work stays on
dedicated serial queues. Protocol value types remain synchronous and testable.

## Build and test

```sh
xcodebuild -project iShareScreen.xcodeproj -scheme iShareScreen \
  -destination 'platform=macOS' build
xcodebuild -project iShareScreen.xcodeproj -scheme iShareScreen \
  -destination 'platform=macOS' test
```

The real-device integration test is opt-in. Set `ISHARESCREEN_TEST_HOST`,
`ISHARESCREEN_TEST_USERNAME`, and `ISHARESCREEN_TEST_PASSWORD` before running
`RFBAuthenticationIntegrationTests/testAuthenticatesAgainstConfiguredMac`.
