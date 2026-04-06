# Support and compatibility

This project implements a narrow RTSP playback scope (RTSP over TCP interleaved, H.264 video only). Camera interoperability varies across vendors and firmware versions.

## Compatibility policy

- Compatibility is **community-supported**.
- Issues are welcome, but reports without protocol evidence are usually not actionable.

## What to include in issues

Please include:

- Camera make/model + firmware
- RTSP URL shape (redact host if needed)
- Whether auth is none/basic/digest
- The `DESCRIBE` SDP (redacted)
- A sanitized RTSP transcript if possible (redact credentials)

See [CONTRIBUTING.md](CONTRIBUTING.md) for more detail.
