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
