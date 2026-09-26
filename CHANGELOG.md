# Changelog

Changes in this fork compared to [KuDoZ007/QP](https://github.com/KuDoZ007/QP).
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## 2026-09-26

### Added

- Build without Xcode: `Package.swift` builds the app with SwiftPM using only the Command Line Tools, and `build.sh` wraps the result in `dist/QuPi.app`, signs it and launches it.

### Changed

- Minimum macOS version lowered from 27 to 26 (Tahoe).
- Posters now load through a new `ArtworkImage` view instead of `AsyncImage(request:)` and `.asyncImageURLSession(_:)`, which only exist on macOS 27. Images are decoded and downsampled off the main thread, and the "Cache Artwork Locally" setting still applies.
- Xcode previews (`#Preview`) are skipped in SwiftPM builds, since previews only work in Xcode. They still work in the Xcode project.
- `.gitignore` now excludes the SwiftPM build output (`.build/` and `dist/`).

### Removed

- Post-download transcoding (`VideoTranscoder.swift`, `TranscodeSettings.swift`, the Converting section and the convert prompt). Its settings were already commented out upstream, so it never ran on a fresh install. FFmpeg is no longer needed.
- `ActivitySection.swift`, which was not used anywhere.
- `QuPi/Secrets.swift` from the repository. Create it locally before building; the README has a template.

### Fixed

- `.gitignore` pointed to `QuPi/QuPi/Secrets.swift` instead of `QuPi/Secrets.swift`, so the secrets file was committed upstream.
