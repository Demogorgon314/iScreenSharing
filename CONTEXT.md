# Screen Sharing Session Context

This context describes the lifecycle that turns Screen Sharing credentials into a session that can be published to the application UI.

## Language

**Authenticated Session**:
An RFB connection that has completed version negotiation, Apple RSA authentication, ClientInit, and ServerInit, but may not yet own the resources required by its selected sharing mode.
_Avoid_: Connected session, raw session

**Ready Session**:
An authenticated session whose selected sharing mode has installed and started all required runtime resources and has passed its final cancellation check. Standard mode additionally requires its first complete framebuffer frame; returning it transfers close ownership to the caller.
_Avoid_: Active session, initialized session

**Session Activation**:
The ownership phase that creates an Authenticated Session, installs and starts the selected sharing mode, and either returns a Ready Session or closes the pending session on failure or cancellation.
_Avoid_: Session setup, post-authentication setup

**Standard Mode**:
The standard RFB framebuffer path using ordered control-transport messages and framebuffer encodings.
_Avoid_: Classic mode, normal VNC

**High-Performance Mode**:
Apple's private Screen Sharing path using encrypted control records and negotiated audio/video media resources.
_Avoid_: Enhanced mode, proprietary VNC

**Session Route**:
The selected networking path for one session. It opens the control transport and, for High-Performance Mode, lazily creates media through the same Direct or Tailscale Adapter and selected remote peer.
_Avoid_: Transport factory, connection type

**Session Input**:
The Authenticated Session's input module. AppKit adapters submit input in MainActor order across all canvases; the input actor owns keyboard pairing and modifier reconciliation and sends through the existing ordered writer. Each canvas identifies its keyboard source so focus loss or removal can release that source's held keys. Tracked keys describe locally processed input, not remote acknowledgment.
_Avoid_: Per-window keyboard state, remote-applied key state
