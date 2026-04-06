# LumaCam Core

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

> **Important**
>
> This repository is the **open-source core**.
> The SwiftUI apps/UI and Xcode project live in a separate, closed-source apps repo (often a sibling folder like `../LumaCam`).
>
> **Do not add app UI to this repo.**

Open-source core libraries that power the LumaCam apps.

This repo intentionally contains **no app UI**. The iPhone/macOS apps live in a separate, closed-source repository and consume these packages via Swift Package Manager.

**License:** Apache License 2.0 — see [LICENSE](LICENSE). For compatibility expectations and how to report issues, see [SUPPORT.md](SUPPORT.md). Release tagging is described in [RELEASING.md](RELEASING.md).

## What’s in scope

- **RTSP over TCP (interleaved)**
- **H.264 video only** (v1), no audio
- RTSP **Basic** + **Digest** authentication
- Fixture-driven protocol stack tests (no camera required)

This is a pragmatic implementation aimed at low-latency live viewing. Camera compatibility varies by vendor/firmware and is treated as **community-supported**.

## Packages

- **LumaCamCore** (`packages/LumaCamCore/Sources/LumaCamCore`)
  - Camera models, persistence helpers, diagnostics flags, reconnect/session coordination, RTSP auth helpers.
- **NativeRTSP** (`packages/NativeRTSP/Sources/NativeRTSP`)
  - RTSP/SDP/RTP/H.264 protocol stack used by the apps.

Both are products of the root [Package.swift](Package.swift).

## Adding as a dependency (SwiftPM)

In your app’s `Package.swift`, add this repository by URL and pin to a [released tag](RELEASING.md). Replace the URL with your fork or the canonical GitHub URL once published:

```swift
dependencies: [
    .package(url: "https://github.com/YOUR_ORG/lumacam-core.git", exact: "0.1.0"),
],
targets: [
    .target(
        name: "YourAppTarget",
        dependencies: [
            .product(name: "LumaCamCore", package: "lumacam-core"),
            .product(name: "NativeRTSP", package: "lumacam-core"),
        ]
    ),
]
```

The `package:` label must match the **dependency** name SwiftPM assigns (by default, the last path segment of the Git URL, here `lumacam-core`). You can instead pass an explicit name: `.package(name: "LumacamCore", url: …)` and then use `package: "LumacamCore"` in `product` dependencies. Library product names are `LumaCamCore` and `NativeRTSP` (see [Package.swift](Package.swift)). In Xcode, use **File → Add Package Dependencies…** and paste the same Git URL.

## Build and test

From the repository root (requires Xcode’s command-line tools / selected developer directory):

```bash
swift test
```

If `swift` does not resolve the macOS SDK (multiple Xcode installs, CI-like environments), point at Xcode explicitly:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Development with the apps (local)

For day-to-day development, the closed-source apps repo can add this repository as a **local package** in Xcode (single dependency at the repo root; enable the **LumaCamCore** and/or **NativeRTSP** products your app needs), e.g.:

- `../lumacam-core`

This is local-only and typically not something you commit. For reproducible release builds, depend on the **public Git URL** of this repository and pin to a **tagged version** (see [RELEASING.md](RELEASING.md)).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security-sensitive reports: [SECURITY.md](SECURITY.md).

