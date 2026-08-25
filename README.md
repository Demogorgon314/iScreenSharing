# iShareScreenSwift

iShareScreenSwift is a native macOS client for Apple's proprietary Screen
Sharing high-performance mode. It targets macOS 15 and implements the Apple RFB
control channel together with the encrypted HEVC, audio, feedback, input, and
clipboard protocols used by Screen Sharing.app.

This is not a general-purpose VNC raster client. The project is focused on
interoperability with modern macOS Screen Sharing hosts and on matching the
observable behavior of Apple's high-performance implementation.

The saved-connection model still contains a `Standard` mode value for data and
UI compatibility, but that mode is not implemented: authentication currently
returns an explicit unsupported-mode error. Only `High Performance` is
operational.

## Current features

- Apple `RFB 003.889` handshake and authentication, encrypted records,
  rekeying, and session lifecycle
- High-performance SRTP/SRTCP media transport with four-tile HEVC video streams
- Multi-tile decoding through Apple's private VideoProcessing (VCP) framework,
  with a public VideoToolbox fallback
- NV24 Metal rendering, display-link pacing, multi-display windows, and cursor
  composition
- RTCP receiver reports, NACK/FIR/LTR feedback, and Apple RCTL bandwidth
  estimation
- Single-display dynamic resolution changes that retain the last decoded frame
  while a fresh media receive/decode generation starts
- Encrypted keyboard, pointer, high-precision scrolling, observe/control mode,
  and Apple remote system commands
- Focus-aware, multi-item clipboard synchronization for inline pasteboard
  flavors, plus keyboard input-source sharing. File URLs, file promises, and
  file transfer are intentionally excluded
- AAC-ELD remote audio with persistent mute state
- Bonjour discovery, Apple device metadata, native device icons, saved
  connections, groups, recent items, and Keychain credentials

## Architecture

```text
SwiftUI/AppKit windows
        │
        ▼
SessionCommandState / SessionManager
        │
        ▼
RFBAuthenticatedSession
        ├── encrypted RFB control and input
        ├── clipboard and keyboard-source services
        └── negotiated UDP media streams
                │
                ▼
        SRTP/RTP receive pipeline
                │
                ▼
        HEVC AU assembly and recovery
                │
                ▼
        VCP or VideoToolbox decoding
                │
                ▼
        display scheduler and Metal renderer
```

Source ownership is divided as follows:

- `App`: application commands, manual session-window lifecycle, and active
  session routing
- `Features/Connections`: SwiftUI presentation, connection library, Metal
  canvas, and view-level coordination
- `Core/Models`: UI- and transport-independent domain values
- `Core/Protocol`: deterministic wire encoders, decoders, cryptography framing,
  RTP/RTCP structures, and media negotiation values
- `Services/Networking`: Network.framework transports, Bonjour, authentication,
  UDP socket delivery, and control/media channel coordination
- `Services/Media`: ordered SRTP/RTP processing, feedback, decoding, playout,
  audio, and frame publication
- `Services/Clipboard`, `Services/Input`, `Services/Security`, and
  `Services/Session`: focused platform adapters and authenticated-session
  resource ownership

Encrypted control writes are serialized because Apple records use chained
cipher state. For each video stream, UDP draining and ordered per-datagram
SRTP/RTP/access-unit processing run on the same dedicated network queue.
Completed access units then move to a playback/decode queue, while rate-control
timers, asynchronous decoder output, and display presentation have separate
scheduling boundaries. Decode and rendering work therefore do not run on the
socket-drain queue.

## Private framework note

For a negotiated four-tile stream, the app dynamically loads these private
VideoProcessing symbols when available:

- `VCPDecompressionSessionCreate`
- `VCPDecompressionSessionDecodeFrame`
- `VCPDecompressionSessionWaitForAsynchronousFrames`

VCP accepts tile identity/order metadata and returns one full-canvas pixel
buffer after its internal tile assembly completes. If the private framework or
symbols are unavailable, the app falls back to public VideoToolbox tile output
and Metal composition.

Private APIs are undocumented and may change between macOS releases. This path
is not suitable for an App Store distribution without replacing it with a
public implementation.

## Requirements

- macOS 15 or later
- Xcode capable of building a macOS 15 target
- A remote Mac with Screen Sharing enabled
- Network access to the remote Screen Sharing service and negotiated UDP media
  ports

The current Xcode project contains a macOS target only. It does not build for
iPhone, iPad, or Mac Catalyst without adding platform-specific UI, input,
clipboard, display-link, and decoder adapters.

## Build and test

```sh
xcodebuild -project iShareScreen.xcodeproj \
  -scheme iShareScreen \
  -destination 'platform=macOS' \
  build

xcodebuild -project iShareScreen.xcodeproj \
  -scheme iShareScreen \
  -destination 'platform=macOS' \
  test
```

Run one test class while iterating:

```sh
xcodebuild -project iShareScreen.xcodeproj \
  -scheme iShareScreen \
  -destination 'platform=macOS' \
  test \
  -only-testing:iShareScreenTests/AppleVideoRateControlTests
```

The real-host authentication integration test is opt-in. Set
`ISHARESCREEN_TEST_HOST`, `ISHARESCREEN_TEST_USERNAME`, and
`ISHARESCREEN_TEST_PASSWORD` before running
`RFBAuthenticationIntegrationTests/testAuthenticatesAgainstConfiguredMac`.
Do not put real credentials in source files or committed schemes.

## Diagnostics

The following environment variables are intended for local development:

- `ISHARESCREEN_DISABLE_VCP=1`: force the public VideoToolbox fallback
- `ISHARESCREEN_RCTL_MODE=estimated|fixed-lan|disabled`: use the native-style
  estimate (the default), force a 60.001 Mbps LAN report, or suppress RCTL
- `ISHARESCREEN_QUALITY_DIAGNOSTICS=1`: enable additional quality logging
- `ISHARESCREEN_FREEZE_DIAGNOSTICS=1`: enable decode/freeze recovery logging
- `ISHARESCREEN_PIPELINE_DIAGNOSTICS=1`: correlate decoder output, playback and
  main-queue delivery, display scheduling, drawable acquisition, Metal GPU
  execution, display-link targets, and physical presentation; emits only
  500 ms aggregate samples rather than per-frame logs. Selecting the persisted
  **Detailed** metrics level enables the same collection for the on-screen
  Video Performance overlay without requiring this environment flag
- The persisted **Metrics Level** menu offers Compact (the default), Standard,
  and Detailed views. Compact uses Moonlight's Rx/Decode/Render layout while
  retaining iShareScreen's actual semantics: bandwidth is this stream's
  delivered video UDP traffic and loss is the primary RTP receiver-report
  loss. Peer RTT and host encode time are omitted because the client cannot
  measure them reliably
- `ISHARESCREEN_VIDEO_RCVBUF_BYTES=<bytes>`: in Debug builds only, override the
  video UDP receive buffer for controlled A/B testing; unset it to retain the
  native-aligned system default

Keep diagnostics disabled in normal builds unless investigating a specific
problem; per-packet logging can materially change media timing.

## Development guidance

Read [`AGENTS.md`](AGENTS.md) before changing protocol or media behavior. Reports
and reverse-engineering notes are useful leads, but they are not ground truth
until verified against the relevant macOS build and represented by a focused
test or wire vector.

## Disclaimer

This project is an independent interoperability effort. It is not affiliated
with or endorsed by Apple. Apple, macOS, Screen Sharing, VideoToolbox, and other
Apple product names are trademarks of Apple Inc.
