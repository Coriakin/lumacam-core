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

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/)-style subjects:

`type(optionalScope): imperative description`

Examples: `feat(LumaCamCore): …`, `fix(NativeRTSP): …`, `test(LumaCamCore): …`, `docs: …`, `chore: …`.

- **Scopes:** Prefer `LumaCamCore` or `NativeRTSP` when the change is localized to that product. Omit the scope for repo-wide edits (for example `Package.swift`, shared CI config).
- **Subject:** Imperative mood (“add”, “fix”), not past tense; about 72 characters is a soft limit.
- **Body:** Add when the motivation, tradeoffs, or non-obvious behavior need explanation. A normal paragraph or a short bullet list is fine.

Git detail: each `git commit -m` argument becomes a separate **paragraph**, separated by a blank line. For a compact bullet body, use a single `-m` with embedded newlines or `git commit -F` with a message file (or shell here-doc), instead of one `-m` per bullet.

If you introduce a breaking API change, describe it in the body and/or use a `BREAKING CHANGE:` footer as in the Conventional Commits spec.

## Changes and code style

- Keep diffs **narrow and reviewable**; do not mix unrelated refactors with a bug fix or feature.
- **Match** naming, structure, and formatting already used in the package you touch (`packages/LumaCamCore`, `packages/NativeRTSP`).
- For protocol and parsing behavior, prefer **fixture-driven tests** (see [CONTRIBUTING.md](CONTRIBUTING.md)).
- Avoid new dependencies that would complicate App Store distribution of downstream apps (see CONTRIBUTING).

## Before you open a PR or push

- Run `swift test` from the repository root (see **Build and test** above).
- For what to put in interoperability bug reports, see [CONTRIBUTING.md](CONTRIBUTING.md) and [SUPPORT.md](SUPPORT.md).
- For security-sensitive issues, use [SECURITY.md](SECURITY.md).
- For release tagging and how apps should pin versions, see [RELEASING.md](RELEASING.md).
