## About this fork

This is a fork of [KuDoZ007/QP](https://github.com/KuDoZ007/QP) with the following changes:

*   **macOS 26 support:** The deployment target is lowered from macOS 27 to macOS 26 (Tahoe). The upstream build relied on two SwiftUI APIs that only exist on macOS 27 (`AsyncImage(request:)` and `.asyncImageURLSession(_:)`).
*   **Artwork loading:** Posters now load through a small `ArtworkImage` view. It keeps the "Cache Artwork Locally" setting, and it decodes and downsamples images off the main thread, which reduces memory use and scrolling hitches.
*   **Cleanup:** Removed the unused `ActivitySection.swift`.
*   **Secrets no longer committed:** `QuPi/Secrets.swift` is now ignored by Git (the upstream `.gitignore` pointed to the wrong path). You need to create it yourself before building; see below.
*   **Builds without Xcode:** `./build.sh` builds and launches the app using only the Command Line Tools.

See [CHANGELOG.md](CHANGELOG.md) for details.

### Building this fork

Requirements: macOS 26 or later, plus either the Command Line Tools (`xcode-select --install`) or Xcode 26.4 or later. The SwiftVLC package requires Swift 6.3.

1.  Create `QuPi/Secrets.swift` with your own credentials:

    ```swift
    enum TraktSecrets {
        static let clientID     = "YOUR_TRAKT_CLIENT_ID"
        static let clientSecret = "YOUR_TRAKT_CLIENT_SECRET"
        static let redirectURI  = "qupi://trakt-auth"
    }

    enum LastFMSecrets {
        static let apiKey       = "YOUR_LASTFM_API_KEY"
        static let sharedSecret = "YOUR_LASTFM_SHARED_SECRET"
        static let callbackURL  = "qupi://lastfm-auth"
    }
    ```

    Trakt: register at https://trakt.tv/oauth/applications/new with redirect URI `qupi://trakt-auth`.
    Last.fm: register at https://www.last.fm/api/account/create with callback URL `qupi://lastfm-auth`.
    The placeholders are enough to build; scrobbling needs real values.
2.  Build and launch:
    *   **Without Xcode:** run `./build.sh`. It builds with SwiftPM, creates `dist/QuPi.app`, signs it and opens it. Use `./build.sh build` to build without launching. Without an Apple Development certificate the app is signed ad-hoc, so macOS asks again for Keychain access after each rebuild.
    *   **With Xcode:** open `QuPi.xcodeproj`, select your own development team under Signing & Capabilities, and run.

---

# QuPi 

**Your entire media library, right from your macOS menu bar.**

QuPi is a sleek, lightweight, and highly customizable menu bar application designed to give you instant access to your Plex or Jellyfin server as well as downloaded media. Whether you want to quickly resume a movie, put on a playlist, or download media for offline use, QuPi keeps your entertainment just a click away without cluttering your desktop.

## Key Features

*   **Quick Access:** Access your Movies, TV Shows, Music, and Playlists directly from the menu bar (`Welcome-QuPi.jpg`).
*   **Dynamic Search & Filtering:** Find exactly what you're looking for instantly. The search bar dynamically filters your library as you type, narrowing down results across all media types (`Dynamic-Filtering.jpg`).
*   **Full Library Exploration:** Easily drill down into your content. Browse from your top-level TV shows down to specific seasons and episodes with a clean, intuitive interface (`Full-Library-Exploration.jpg`).
*   **Integrated Playback:**
    *   **Inline Music Player:** Control your tunes without opening a separate window. The inline player lives right inside the menu bar dropdown (`Inline-Music-Player.jpg`).
    *   **Mini Video Player:** Watch your favorite shows while you work using the floating picture-in-picture video player (`Mini-Video-Player.jpg`).
*   **Offline Downloads:** Queue up movies and episodes to download locally so you can enjoy your media on the go (`Download-Queue.jpg`).
*   **Highly Customizable UI:** Tailor QuPi to your exact preferences. 
    *   Toggle specific media sections on or off, adjust the player UI size, and configure carousel items (`Customisation.jpg`).
    *   Switch to a streamlined view for a cleaner look (`Compact-Mode.jpg`).

## Screenshots

![Welcome.](/Screenshots/Welcome-QuPi.png)
![Simple Visuals Mode.](/Screenshots/Compact-Mode.png)
![Mini Video Player.](/Screenshots/Mini-Video-Player.png)
![Inline Music Player.](/Screenshots/Inline-Music-Player.png)
![Full Library Exploration.](/Screenshots/Full-Library-Exploration.png)
![Download Queue.](/Screenshots/Download-Queue.png)
![Dynamic Filtering.](/Screenshots/Dynamic-Filtering.png)
![Customisation.](/Screenshots/Customisation.png)

## Disclaimer

Have used Gemini and Claude to help me build this; though all the prototyping, testing and rewrites are on me.

## Prerequisites

*   macOS 26 (Tahoe) or later
*   FFmpeg installed locally for offline fallback play — brew install ffmpeg
*   A Plex Media Server, Jellyfin Server or local media files

## Getting Started
*   Download the DMG
*   Package is currently unsigned, so you'll need to do the usual 2 step shuffle in Security settings
