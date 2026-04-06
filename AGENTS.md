# LumaCam Core — agent notes

This repo contains the **open-source core** used by the closed-source LumaCam apps.

## What lives here

- `packages/NativeRTSP`: RTSP/SDP/RTP/H.264 protocol stack (v1 scope: RTSP over TCP interleaved, H.264 video only, no audio).
- `packages/LumaCamCore`: camera models, auth helpers, playback/session coordination, persistence helpers, diagnostics.

## What does NOT live here

- App UI (SwiftUI), Xcode project files, StoreKit, app navigation.

Those live in the separate apps repo (typically a sibling folder like `../LumaCam`) which consumes this repo via Swift Package Manager.

## Build and test

From the repository root:

```bash
swift test
```

If needed:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Development workflow with the apps

- For fast local iteration, the apps repo should add this repo as a **local Swift package** (root path) and depend on the **LumaCamCore** and/or **NativeRTSP** products, e.g. `../lumacam-core`.
- For releases, the apps repo should depend on a **tagged version** of this repo (SemVer tags like `v0.3.0`). See [RELEASING.md](RELEASING.md).
