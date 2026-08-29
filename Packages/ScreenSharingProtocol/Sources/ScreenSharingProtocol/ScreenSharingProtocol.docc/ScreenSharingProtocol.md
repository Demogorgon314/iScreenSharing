# ``ScreenSharingProtocol``

Encode and parse the deterministic wire protocol used by RFB and Apple's
Screen Sharing high-performance mode.

## Overview

ScreenSharingProtocol is a macOS-first protocol library. It provides value
types, parsers, encoders, and stateful cryptographic record processors without
owning a network transport or application session.

Use ``RFBProtocol`` and ``RFBServerInfo`` for the initial handshake, then use
the Apple control and media types required by the negotiated mode. A consuming
application owns socket reads and writes, authentication flow, connection
lifecycle, queue scheduling, decoding, rendering, and platform integration.

The private high-performance behavior represented here is verified against
macOS 15.7.7 (24G720). Treat behavior on other releases as unverified until it
has runtime evidence and a deterministic test.

### Stateful processors

``AppleEncryptedRecordLayer`` maintains chained CBC state and send/receive
counters for one authenticated connection. Its output must be delivered by one
ordered writer. Its encrypted pointer and keyboard methods reuse the layer's
stored content key without requiring it as a per-message argument.

``AppleSRTPDecryptor`` and ``AppleSRTCPEncryptor`` maintain rollover or index
state for negotiated media. Preserve packet arrival order at those seams; move
decoding and rendering work to application-owned queues after protocol
processing.

### Package boundary

The package intentionally excludes Network.framework, AppKit, SwiftUI,
Tailscale, VideoToolbox, private decoder frameworks, Metal, Pasteboard access,
and file-copy helper lifecycle. It is a wire-protocol core rather than a
complete Session SDK or a cross-platform compatibility promise.

## Topics

### RFB handshake

- ``RFBProtocol``
- ``RFBVersion``
- ``RFBSecurityType``
- ``RFBServerInfo``
- ``AppleRSA1``

### Encrypted control

- ``AppleRecordKeys``
- ``AppleEncryptedRecordLayer``
- ``AppleEncryptedRecordError``
- ``AppleRFBMessages``
- ``AppleRekey``

### Media wire protocol

- ``AppleMediaOffer``
- ``AppleMediaConfiguration``
- ``AppleSRTPDecryptor``
- ``AppleSRTCPEncryptor``
- ``AppleRTCP``
- ``AppleHEVCNALUnit``
- ``AppleVideoRateControlInfo``

### Session data formats

- ``AppleDisplayConfiguration``
- ``AppleFramebufferUpdate``
- ``AppleClipboardMessage``
- ``AppleFileTransferMessage``
- ``AppleKeyboardInputSourceMessage``
