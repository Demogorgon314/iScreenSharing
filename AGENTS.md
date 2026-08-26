# Agent Development Guide

This file is the working contract for coding agents contributing to
iScreenSharing. Read it together with `README.md` before making changes.

## Mission and scope

The project reproduces Apple's Screen Sharing **high-performance** behavior. It
is not a conventional VNC framebuffer implementation. Favor fidelity to the
native protocol and lifecycle over generic VNC assumptions.

The current reference environment is macOS 15.7.7 (24G720). Behavior observed
on another release must be labeled with that build; do not silently generalize
private implementation details across releases.

## Ground-truth policy

Use this evidence order for protocol and native-behavior work:

1. A reproducible runtime capture or hook from the relevant code path
2. A complete static call chain with inputs, branches, and consumers
3. A deterministic local oracle or golden wire vector
4. Existing production code and tests
5. Reverse-engineering reports as leads only

Reports under external reverse-engineering work directories are not
automatically correct. Conflicting reports must be resolved before production
changes. Record confirmed, inferred, and unknown facts separately.

Never guess a private field, timer, byte order, queue boundary, or recovery
policy. If evidence is incomplete, add instrumentation or ask for a narrowly
defined investigation instead of baking a hypothesis into production code.

## Start-of-task checklist

1. Run `git status --short`; existing changes belong to the user.
2. Read the files that own the behavior and at least three nearby examples or
   tests before choosing an implementation pattern.
3. Identify the single state/lifecycle owner and the public seam to test.
4. For protocol work, write down the exact input, output, byte order, length,
   clock domain, and error behavior.
5. Prefer the smallest change that matches the native architecture.

## Architecture and ownership

### Session and commands

- `RFBAuthenticatedSession` owns one authenticated connection and its control,
  input, clipboard, audio, and video resources.
- `SessionWindowCoordinator` owns manually created AppKit session windows.
- `SessionCommandState` is the single observable façade for session commands,
  toolbar state, and menu checkmarks.
- `ActiveSessionCommandRouter` maps the AppKit key window to the application
  command menu. Do not reintroduce copied session state through multiple
  `FocusedValue` payloads.
- UI-published state belongs on `@MainActor`. Do not keep independent optimistic
  copies in views and services.

### Control transport

- Apple encrypted records have ordered, chained cipher state. Encryption and
  transport delivery must remain serialized by the outbound writer.
- Do not create detached `Task` send paths that can reorder encrypted records.
- Wire encoders and parsers live in `Core/Protocol` and must not import AppKit,
  SwiftUI, or Network.framework.

### Media scheduling

- A video's read source and its ordered per-datagram SRTP/RTP/access-unit work
  intentionally share that stream's `networkQueue`. Completed access units are
  handed to the playback queue; the RCTL timer uses `feedbackQueue`; decoder
  output and display presentation cross their own scheduling boundaries.
- Never submit decoding, perform rendering, or wait for asynchronous decoder
  output on `networkQueue`.
- Preserve packet arrival order at the rate-control and RTP recovery seams.
- Avoid unbounded dispatch fan-out. Backlog ownership and drop behavior must be
  explicit and observable.

### HEVC and decoding

- `AppleHEVCStreamProcessor` owns SRTP/RTP parsing and access-unit assembly.
- `AppleHEVCDecodePipeline` owns DON admission, playout anchoring, decoder
  callbacks, and refresh requests for one negotiated video stream.
- Recoverable reference failures request native protocol refresh and continue
  submissions. Do not replace the decoder merely because a packet or reference
  is missing.
- Within an active media generation, a parameter-set/format change replaces
  only the decoder session. Preserve the surrounding receive pipeline, playout
  state, and retained displayed frame.
- `AppleVCPDecompressionSession` is a runtime-loaded private adapter. Keep the
  public VideoToolbox fallback functional and covered by tests.
- VCP's `TileOrder` is session-local and starts at zero in this implementation;
  changes to its metadata contract require native evidence and fixed vectors.

### Rendering and dynamic changes

- `AppleNV24MetalLayer` is the renderer. Do not restore obsolete
  `AVSampleBufferDisplayLayer` assumptions.
- Display-link cadence follows the window's current screen and can change when
  the window moves between displays.
- The current dynamic-resolution path updates presentation geometry, starts a
  fresh media receive/decode generation, and replays media configuration after
  the server layout changes. This is distinct from an in-generation decoder
  format replacement.
- Both paths must retain the last visible frame until replacement output
  arrives. Never clear the frame store or add a black preparing overlay during
  either transition.
- Layout/control notifications and authoritative media configuration are
  separate signals; do not conflate them without call-chain evidence.

## Protocol guardrails

- Preserve unsigned wrap semantics for RTP sequence numbers, RTP timestamps,
  DON, TileOrder, and RTCP counters.
- Distinguish RTP payload bytes, decrypted RTP packet bytes, SRTP datagram bytes,
  and network throughput. Never substitute one size domain for another.
- Use monotonic time for media arrival/playout calculations and keep clock
  domains explicit. The current rate-control and incomplete-AU paths use
  24,000 Hz, while `AppleVideoPlayoutClock` currently defaults to 90,000 Hz;
  no single negotiated clock value is propagated through both paths. Do not
  substitute or unify these rates without protocol evidence and focused tests
  for each consumer.
- The four HEVC tile SSRCs form one logical video stream where the native path
  does so; do not invent per-SSRC bandwidth estimators or frame barriers.
- RTCP packet type, FMT, APP name, common-header length, sender SSRC, media SSRC,
  and FCI byte order all need golden-vector tests.
- Do not infer LTR, refresh, or probe semantics from similarly named bits. Trace
  the producer and consumer for the exact field.
- Clipboard archives contain repeated item records; each item owns its own
  flavor count. Preserve binary values, aliases, reserved fields, and multiple
  items instead of flattening to text.
- Clipboard synchronization covers inline pasteboard flavors. The current
  implementation deliberately filters file URLs and file-promise types; do not
  describe it as file transfer or add file semantics to the inline archive
  without tracing the native file-transfer protocol.
- DeviceInfo framebuffer encoding is 1110 (`0x456`); UserInfo is 1102. Bonjour
  hardware metadata comes from the sibling `_device-info._tcp` TXT record, not
  the `_rfb._tcp` service TXT record.

## Code quality

- Follow existing naming, import ordering, actor/queue ownership, and error
  patterns.
- Keep wire types deterministic and value-oriented.
- Prefer one deep module with a narrow interface over state spread across views,
  policies, and callbacks.
- Keep functions single-purpose and avoid speculative abstractions.
- Preserve unrelated working-tree changes. Use `apply_patch` for routine edits.
- Do not expose credentials, encryption material, raw clipboard contents, or
  private user data in logs.
- Private framework expansion requires an explicit reason, runtime availability
  checks, graceful fallback, and tests for the unsupported path.

## Performance optimization

- Every performance optimization must include reproducible, quantitative
  before-and-after measurements using the same workload and metric definitions.

## Tests and Documentation

- Add tests for realistic observable regressions, non-trivial invariants or
  boundaries, and concrete bugs. Code changing or coverage increasing is not
  sufficient justification by itself.
- Prefer existing coverage at the behavior boundary. Avoid tests that mirror
  literals, mappings, obvious control flow, implementation details, or removed
  features unless absence is itself a contract. For concurrency, prefer
  deterministic coordination or controlled scheduling over sleeps when
  practical.
- Comments should explain non-obvious rationale, invariants, safety constraints,
  or external quirks rather than restating code. Public API documentation should
  describe observable contracts, not incidental implementation details.

Every public parser, encoder, state transition, and boundary condition changed
by a task needs focused coverage. Prefer:

- exact wire/golden vectors for protocol code
- fake clocks and deterministic timestamps for media logic
- fake transports/decoders for failure and ordering tests
- malformed, truncated, oversized, duplicate, wraparound, and cancellation
  cases
- lifecycle tests for reconnect, close, reconfigure, and late callbacks

Run a focused test while iterating, then the complete suite before handoff:

```sh
xcodebuild -project iScreenSharing.xcodeproj \
  -scheme iScreenSharing \
  -destination 'platform=macOS' \
  test \
  -only-testing:iScreenSharingTests/TestClassName

xcodebuild -project iScreenSharing.xcodeproj \
  -scheme iScreenSharing \
  -destination 'platform=macOS' \
  test
```

The real-host authentication test is opt-in and must not run without explicit
credentials in `ISHARESCREEN_TEST_HOST`, `ISHARESCREEN_TEST_USERNAME`, and
`ISHARESCREEN_TEST_PASSWORD`.

When enabling per-packet diagnostics, account for observer effects: logging can
change queue timing and invalidate a performance conclusion.

## Reverse-engineering handoff

For any conclusion derived from a binary, report:

- operating-system build and binary/image
- symbol or image-relative address
- caller and consumer chain
- exact structure offsets and byte order, when applicable
- whether the result is static, dynamically observed, inferred, or still
  unknown
- a minimal production test or oracle that guards the conclusion

Do not describe a generic framework path as the active Screen Sharing path until
the construction and dispatch chain is closed.

## Completion checklist

- The requested behavior is implemented at the correct ownership boundary.
- Focused tests and the full suite pass.
- `git diff --check` is clean.
- No build artifacts, packet captures, credentials, or reverse-engineering
  databases are staged.
- The handoff states what changed, what was verified, and any remaining unknowns.
