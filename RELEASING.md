# Releasing `lumacam-core`

This repo is consumed by a separate, closed-source apps repo via Swift Package Manager.

## Versioning

Use SemVer tags:

- `v0.x.y` while the API is still changing
- `v1.0.0` once you want stability guarantees

## Release steps

1. Make sure CI is green and local tests pass from the **repository root**:

```bash
swift test
```

On a machine with multiple Xcode installs, use:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

2. Commit changes on `main`.
3. Create a git tag, e.g. `v0.3.0`.
4. In the apps repo, switch the package dependency from Local Package to the Git URL (or update the pinned version to the new tag) for App Store builds.

## Notes

- Local Packages are great for rapid iteration but are generally developer-machine specific.
- Tagged releases make builds reproducible and are recommended for CI and App Store submission.
