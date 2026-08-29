# iScreenSharing

iScreenSharing is a native macOS client for Apple Screen Sharing. It targets
macOS 15 and supports both the standard RFB framebuffer path and Apple's
proprietary high-performance mode, including its encrypted HEVC, audio,
feedback, input, clipboard, and file-transfer protocols.

The project remains focused on interoperability with modern macOS Screen
Sharing hosts. Standard mode uses the shared Apple RSA authentication path,
then standard RFB ClientInit, pixel-format, encoding, framebuffer-update, key,
and pointer messages. It currently supports Hextile with Raw fallback and
DesktopSize updates. It is not intended to cover every VNC security type or
vendor extension.

## Current features

- Standard Screen Sharing with selectable 32-bit color, 16-bit color,
  16-level grayscale, or monochrome low-bandwidth quality; persistent-stream
  Apple SubZlib Halftone and SubZlib16Gray, standard Zlib, Hextile, Raw, and
  CopyRect decoding,
  dynamic server framebuffer size,
  standard keyboard/pointer input, and the existing BGRA Metal presentation
  path. Standard-mode clipboard, audio, file transfer, and client-requested
  desktop resizing are not currently exposed
- Apple `RFB 003.889` handshake and authentication, encrypted records,
  rekeying, and session lifecycle
- High-performance SRTP/SRTCP media transport with four-tile HEVC video streams
- Selectable multi-tile decoding through Apple's private VideoProcessing (VCP)
  framework or a public seamless VideoToolbox path with atomic Metal
  presentation; an unsynchronized low-latency path remains available for
  developer testing
- NV24 Metal rendering, display-link pacing, multi-display windows, and cursor
  composition
- RTCP receiver reports, NACK/FIR/LTR feedback, and Apple RCTL bandwidth
  estimation
- Single-display dynamic resolution changes that retain the last decoded frame
  while a fresh media receive/decode generation starts
- Encrypted keyboard, pointer, high-precision scrolling, observe/control mode,
  and Apple remote system commands
- Focus-aware, multi-item clipboard synchronization for inline pasteboard
  flavors, plus keyboard input-source sharing. Clipboard file URLs and file
  promises remain filtered because file transfer uses a separate protocol
- Viewer-to-host transfer of one regular file at a time by dragging it onto the
  remote canvas, with transfer progress and per-session history. The feature is
  offered only when the host advertises both required server commands; folders,
  symbolic links, multiple-item drops, and host-to-viewer transfer are not yet
  exposed
- AAC-ELD remote audio with persistent mute state
- Bonjour discovery, Apple device metadata, native device icons, saved
  connections, groups, recent items, and Keychain credentials
- An embedded userspace Tailscale node with browser login, peer discovery,
  encrypted on-disk state, and RFB TCP plus packet-preserving UDP media routed
  through the tailnet, plus native account status and logout controls in Settings

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
        ├── clipboard, file-transfer, and keyboard-source services
        └── negotiated UDP media streams
                │
                ▼
        SRTP/RTP receive pipeline
                │
                ▼
        HEVC AU assembly and recovery
                │
                ▼
        VCP or public VideoToolbox decoding
                │
                ▼
        display scheduler and Metal renderer
```

Direct and Tailscale sessions share the same authenticated-session and media
pipelines. Direct sessions use Network.framework and Darwin UDP sockets;
Tailscale sessions select the embedded `libtailscale` TCP and packet UDP
adapters at the transport boundary. The remote Mac must still be signed in to
the same tailnet and have Screen Sharing enabled.

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
- `Services/Clipboard`, `Services/FileTransfer`, `Services/Input`,
  `Services/Security`, and `Services/Session`: focused platform adapters and
  authenticated-session resource ownership

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
symbols are unavailable, the app falls back to public VideoToolbox tile output.
The seamless public path groups the sender's sparse tile updates by frame
sequence number and publishes each completed group as one observable snapshot;
the low-latency path publishes decoded tiles immediately. Metal draws either
snapshot in one drawable and one command buffer without first copying it into a
new pixel buffer. The session menu and Display settings expose VCP and seamless
VideoToolbox as product choices; low-latency VideoToolbox and presentation
synchronization live only under Developer / Experimental in Display settings.
VCP selection still degrades safely when the private symbols are unavailable.
Frame grouping, late-callback rejection, and zero-copy buffer handoff have
deterministic coverage.

Viewer-to-host file transfer also launches ScreenSharing.framework's
`SSFileCopySenderFW` helper when it is available. The helper is the native owner
of Finder metadata, resource-fork, extended-attribute, and compressed file-copy
frames; iScreenSharing validates and forwards those frames through its ordered
encrypted writer. If the helper or the required host commands are unavailable,
file drops fail closed instead of using an inferred wire format.
The file-transfer wire contract and helper adapter are verified against macOS
15.7.7 (24G720); capability checks and strict frame validation remain in place
on other releases because these interfaces are private.

Private APIs are undocumented and may change between macOS releases. This path
is not suitable for an App Store distribution without replacing it with a
public implementation.

## Requirements

- macOS 15 or later
- Xcode capable of building a macOS 15 target
- A remote Mac with Screen Sharing enabled
- Network access to the remote Screen Sharing service and negotiated UDP media
  ports
- Go 1.25.5 or later when rebuilding the embedded Tailscale framework
- Apple silicon for the current embedded Tailscale framework build

The current Xcode project contains a macOS target only. It does not build for
iPhone, iPad, or Mac Catalyst without adding platform-specific UI, input,
clipboard, display-link, and decoder adapters.

## Build and test

```sh
git submodule update --init --recursive

xcodebuild -project iScreenSharing.xcodeproj \
  -scheme iScreenSharing \
  -destination 'platform=macOS' \
  build

xcodebuild -project iScreenSharing.xcodeproj \
  -scheme iScreenSharing \
  -destination 'platform=macOS' \
  test
```

The app target builds `Dependencies/libtailscale/swift/TailscaleKit.framework`
on demand and embeds it in the application bundle. Tailscale's persistent node
state is encrypted with a random 32-byte key stored in the user's Keychain; the
key and state must be kept together across app updates.

Run one test class while iterating:

```sh
xcodebuild -project iScreenSharing.xcodeproj \
  -scheme iScreenSharing \
  -destination 'platform=macOS' \
  test \
  -only-testing:iScreenSharingTests/AppleVideoRateControlTests
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
  estimate (the default), force a diagnostic 60.001 Mbps report, or suppress
  RCTL
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
  retaining iScreenSharing's actual semantics: bandwidth is this stream's
  delivered video UDP traffic and loss is the primary RTP receiver-report
  loss. Peer RTT and host encode time are omitted because the client cannot
  measure them reliably. For embedded Tailscale sessions, Detailed also shows
  the active route, gVisor ingress-age p50/p95/p99/maximum, and receive-buffer
  overflow deltas. Ingress age is measured before the Swift receive loop, so it
  includes time hidden inside the embedded userspace UDP queue
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
