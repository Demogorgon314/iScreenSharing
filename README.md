# iShareScreenSwift

A native macOS client for Apple's Screen Sharing protocol, implemented in Swift.

## Architecture

- `App`: application lifecycle and scene composition
- `Features`: feature-owned views and presentation models
- `Core/Models`: domain values with no UI or network dependencies
- `Core/Protocol`: byte-level Apple RFB 3.889 protocol types
- `Services`: macOS integrations and network transports

The app uses SwiftUI for window and toolbar composition, Network.framework for
TCP transport, and keeps protocol parsing independent so it can be covered by
unit tests.

## Build and test

```sh
xcodebuild -project iShareScreen.xcodeproj -scheme iShareScreen \
  -destination 'platform=macOS' build
xcodebuild -project iShareScreen.xcodeproj -scheme iShareScreen \
  -destination 'platform=macOS' test
```

