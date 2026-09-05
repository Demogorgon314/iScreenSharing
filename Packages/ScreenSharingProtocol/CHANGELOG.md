# Changelog

This file records user-visible changes to the public `ScreenSharingProtocol`
interface. Protocol conclusions are still qualified by the verified macOS
build documented in the package README.

## 0.1.0 — Unreleased

- Establish the initial local-package interface for deterministic Standard RFB
  and Apple Screen Sharing high-performance wire protocols.
- Cover the public protocol seam with independent tests, DocC documentation,
  and a package-external compile smoke fixture.
- Declare the package-specific MIT license and pre-1.0 compatibility policy.
- Fix independent sync-flush decompression losing buffered output above 64 KiB.
  `decompressSyncFlush` now throws `invalidStream` when the decoded length does
  not match `expectedSize`, instead of returning incomplete or mismatched data.
  Empty streams and completed zlib streams remain supported.

No Git tag has been published for this version. Consumers should continue to
use a local path or pin a known repository commit.
