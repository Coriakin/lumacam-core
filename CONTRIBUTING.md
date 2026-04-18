# Contributing to LumaCam Core

Thanks for helping improve camera compatibility and stability.

Repository conventions for **commit messages**, scopes, and expectations for AI-assisted or automated edits are summarized in [AGENTS.md](AGENTS.md).

## Quick start

Run tests from the repository root:

```bash
swift test
```

If needed (multiple Xcode installs):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

For compatibility reporting guidelines, see [SUPPORT.md](SUPPORT.md).

## What to include in bug reports

Camera interoperability bugs are usually only actionable with protocol evidence. Please include:

- Camera make/model and firmware version
- RTSP URL shape (redact host if needed)
- Authentication mode (none/basic/digest)
- A sanitized RTSP transcript if possible (requests/responses; redact credentials)
- SDP from `DESCRIBE` (often enough to reproduce parser/track selection issues)
- If available: RTP payload samples (PCAP or redacted hexdumps) for depacketizer issues

## Pull requests

- Add or extend fixture-driven tests whenever possible.
- Keep changes narrowly scoped.
- Avoid introducing dependencies that would complicate App Store distribution.

## License

By contributing, you agree that your contributions will be licensed under the project’s Apache-2.0 license (see [LICENSE](LICENSE)).
