import Foundation

/// The kinds of media catalogs providers can serve.
enum MediaType: String, CaseIterable, Identifiable, Codable {
    case movies = "Movies"
    case tvShows = "TV Shows"
    case music = "Music"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .movies: "film"
        case .tvShows: "tv"
        case .music: "music.note"
        }
    }
}

/// The sections of the menu bar dropdown. The first three map to a
/// MediaType; Playlists and Continue… are cross-cutting.
enum MenuSection: String, CaseIterable, Identifiable, Codable {
    case movies
    case tvShows
    case music
    case playlists
    case continueItems

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movies: "Movies"
        case .tvShows: "TV Shows"
        case .music: "Music"
        case .playlists: "Playlists"
        case .continueItems: "Continue…"
        }
    }

    var systemImage: String {
        switch self {
        case .movies: "film"
        case .tvShows: "tv"
        case .music: "music.note"
        case .playlists: "music.note.list"
        case .continueItems: "clock.arrow.circlepath"
        }
    }

    var mediaType: MediaType? {
        switch self {
        case .movies: .movies
        case .tvShows: .tvShows
        case .music: .music
        case .playlists, .continueItems: nil
        }
    }

    /// Sections whose tracks play with the inline music overlay. Continue…
    /// is included so its grouped album/playlist cells can host the overlay.
    var supportsInlineMusic: Bool {
        self == .music || self == .playlists || self == .continueItems
    }

    var enabledByDefault: Bool {
        switch self {
        case .movies, .tvShows, .music: true
        case .playlists, .continueItems: false
        }
    }

    /// Loading-placeholder height while a section's catalog fetches.
    var loadingHeight: CGFloat {
        switch self {
        case .music, .playlists: 110
        case .movies, .tvShows, .continueItems: 165
        }
    }
}

/// Which backend an item came from; used to route stream resolution and
/// playback reporting.
enum MediaSource: String, Codable, Hashable {
    case sample
    case plex
    case jellyfin
    /// Locally downloaded content, served by LocalMediaProvider.
    case local
}

/// Which hierarchy levels expose a download control. Movies always show
/// the control (governed by the master downloads toggle); TV and Music
/// levels are individually opt-in and default to off.
enum DownloadLevel: String, CaseIterable {
    case movie
    case series    // show
    case season
    case episode
    case playlist
    case artist
    case album
    case song      // track

    var kind: MediaKind {
        switch self {
        case .movie: .movie
        case .series: .show
        case .season: .season
        case .episode: .episode
        case .playlist: .playlist
        case .artist: .artist
        case .album: .album
        case .song: .track
        }
    }

    init?(kind: MediaKind) {
        switch kind {
        case .movie: self = .movie
        case .show: self = .series
        case .season: self = .season
        case .episode: self = .episode
        case .playlist: self = .playlist
        case .artist: self = .artist
        case .album: self = .album
        case .track: self = .song
        }
    }
}

/// Player lifecycle states reported to media servers and scrobblers.
enum PlaybackState {
    case started
    case playing
    case paused
    case stopped
}

/// Where an item sits in its hierarchy. Containers expand into a child
/// carousel in the dropdown; leaves open the player.
enum MediaKind: String, Codable, Hashable {
    case movie
    case show
    case season
    case episode
    case artist
    case album
    case track
    case playlist

    var isExpandable: Bool {
        switch self {
        case .show, .season, .artist, .album, .playlist: true
        case .movie, .episode, .track: false
        }
    }
}

// MARK: - Preferences

/// What the TV section lists at its top level.
enum TVTopLevel: String, CaseIterable {
    case series
    case season
}

/// What the Music section lists at its top level.
enum MusicTopLevel: String, CaseIterable {
    case artist
    case album
}

/// How to pick the next movie when one finishes.
enum MovieAutoContinue: String, CaseIterable {
    case off
    case inSequence
    case byDirector
    case byLeadActor
}

/// How music continues when a track finishes. `.off` still advances through
/// the album/playlist in order; `.shuffleByArtist` jumps to random tracks by
/// the same artist.
enum MusicAutoContinue: String, CaseIterable {
    case off
    case inSequence
    case shuffleByGenre
}

/// Whether the Continue… section lists individual in-progress songs or
/// collapses them into their parent album/playlist.
enum ContinueMusicGrouping: String, CaseIterable {
    case byAlbumPlaylist
    case bySong
}

/// How long unfinished items stay in the Continue… section.
enum ContinueTimeout: String, CaseIterable {
    case day = "24h"
    case threeDays = "72h"
    case week = "1w"
    case forever

    var title: String {
        switch self {
        case .day: "24 hours"
        case .threeDays: "72 hours"
        case .week: "1 week"
        case .forever: "Forever"
        }
    }

    /// Nil means never expire.
    var maxAge: TimeInterval? {
        switch self {
        case .day: 24 * 3600
        case .threeDays: 72 * 3600
        case .week: 7 * 24 * 3600
        case .forever: nil
        }
    }
}

/// Size of player window UI elements (volume slider, toolbar items).
enum PlayerUISize: String, CaseIterable {
    case small, medium, large, dynamic

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .dynamic: "Dynamic"
        }
    }
}

/// Music player display mode: inline or popout floating window.
enum PlayerMode: String, CaseIterable {
    case inline, popout

    var title: String {
        switch self {
        case .inline: "Inline"
        case .popout: "Popout"
        }
    }
}

/// Sort order for the Movies section.
enum MovieSort: String, CaseIterable {
    case byTitle
    case byYear
    case byDateAdded
    case byPlays
}

/// Sort order for the TV Shows section.
enum TVSort: String, CaseIterable {
    case byTitle
    case byYear
    case byDateAdded
    case byPlays
}

/// Sort order for the Music section.
enum MusicSort: String, CaseIterable {
    case byArtist
    case byTitle
    case byYear
    case byDateAdded
    case byPlays
}

/// Ascending or descending order for section sorting.
enum SortDirection: String, CaseIterable {
    case ascending
    case descending
}

// MARK: - Items

/// A single piece of media, source-agnostic.
/// Codable + Hashable so it can be handed to `WindowGroup(for:)` to open a player window.
struct MediaItem: Identifiable, Hashable, Codable {
    var id: String
    var source: MediaSource = .sample
    var type: MediaType
    var kind: MediaKind = .movie
    var title: String
    var subtitle: String?
    var posterURL: URL?
    /// Known up-front for Plex items; resolved lazily otherwise.
    var streamURL: URL?
    var summary: String?
    /// The container this item was listed under (season for an episode,
    /// album/playlist for a track); lets auto-continue and the music queue
    /// find siblings.
    var parentID: String?
    var parentKind: MediaKind?
    /// Display info for the container above, so a track can rebuild its parent
    /// album/playlist cell in the grouped Continue… section without a fetch.
    var parentTitle: String?
    var parentPosterURL: URL?
    /// Source-specific extras (artist IDs, release dates, …) that
    /// auto-continue needs but the UI doesn't.
    var attributes: [String: String] = [:]
    /// Date the item was added to the library. Nil when the backend does not report it.
    var addedAt: Date?
    /// Total play count. Nil when the backend does not report it.
    var playCount: Int?

    /// Release year when the subtitle carries one (used for Trakt matching).
    var year: Int? {
        subtitle.flatMap { Int($0) }
    }

    /// Year for sorting — falls back to the releaseDate attribute when
    /// the subtitle is not a plain year (e.g. for music or TV seasons).
    var sortableYear: Int? {
        year ?? Int(attributes["releaseDate"]?.prefix(4) ?? "")
    }

    /// Globally-unique identity for SwiftUI rendering. `id` alone is a Plex
    /// ratingKey, which can collide across servers; scoping it by source and
    /// originating server keeps `ForEach`/`scrollPosition` identities distinct
    /// when multiple servers each expose the same library type.
    var uniqueID: String {
        let server = attributes["plexServerID"] ?? ""
        return "\(source.rawValue)|\(server)|\(id)"
    }

    /// Carousel cell artwork height: 2:3 portrait for movies/shows/seasons,
    /// 16:9 landscape for episode stills, square for music art.
    var posterHeight: CGFloat {
        switch kind {
        case .episode: 62
        case .artist, .album, .track, .playlist: 110
        case .movie, .show, .season: 165
        }
    }
}

// MARK: - Providers

/// Abstracts where media comes from so the UI works identically with the
/// sample catalog, Plex, and Jellyfin.
protocol MediaProvider {
    var source: MediaSource { get }
    func items(for type: MediaType) async throws -> [MediaItem]
    /// Children of a container: a show's seasons, a season's episodes,
    /// an artist's albums, an album's or playlist's tracks.
    func children(of item: MediaItem) async throws -> [MediaItem]
    /// The user's playlists, when the backend has them.
    func playlists() async throws -> [MediaItem]
    /// Deep search: each result is an ancestor chain from the configured
    /// top level down to the matched item (e.g. artist → album → track for
    /// a matched track title), so the dropdown can filter every drill level.
    func deepSearch(_ query: String, type: MediaType) async throws -> [[MediaItem]]
    func streamURL(for item: MediaItem) async throws -> URL
    /// The direct-file download URL for the original media, distinct from
    /// `streamURL` which may return an HLS playlist for transcoding.
    func downloadURL(for item: MediaItem) async throws -> URL
    /// The next movie per the auto-continue criterion, or nil when the
    /// backend can't answer it.
    func nextMovie(after item: MediaItem, by criterion: MovieAutoContinue) async throws -> MediaItem?
    /// A random other track by the same artist, for shuffle auto-continue.
    func randomTrack(sameArtistAs item: MediaItem) async throws -> MediaItem?
}

extension MediaProvider {
    func playlists() async throws -> [MediaItem] { [] }
    func deepSearch(_ query: String, type: MediaType) async throws -> [[MediaItem]] { [] }
    func downloadURL(for item: MediaItem) async throws -> URL { throw URLError(.unsupportedURL) }
    func nextMovie(after item: MediaItem, by criterion: MovieAutoContinue) async throws -> MediaItem? { nil }
    func randomTrack(sameArtistAs item: MediaItem) async throws -> MediaItem? { nil }
}

/// Returns true when AVFoundation can decode the file at `url` without
/// transcoding. Network URLs (HLS streams) always pass — the server already
/// produces a compatible format. Local files are checked by container extension;
/// anything not in the allowlist (e.g. .mkv, .avi) requires the SwiftVLC engine.
func isAVFoundationPlayable(_ url: URL) -> Bool {
    guard url.isFileURL else { return true }
    let ext = url.pathExtension.lowercased()
    let supported: Set<String> = [
        // Video containers AVFoundation can open directly
        "mp4", "m4v", "mov",
        // Audio containers AVFoundation handles natively
        "mp3", "m4a", "aac", "flac", "aiff", "wav", "caf",
    ]
    return supported.contains(ext)
}

/// Strips sequel numbering and subtitles ("Movie 2", "Movie II: Subtitle")
/// so franchise entries compare equal for In Sequence auto-continue.
func franchiseBaseTitle(_ title: String) -> String {
    var base = title
    if let colon = base.firstIndex(of: ":") {
        base = String(base[..<colon])
    }
    while let last = base.split(separator: " ").last,
          last.allSatisfy({ $0.isNumber }) || last.allSatisfy({ "IVXLC".contains($0) }) && last.count <= 4 {
        base = base.dropLast(last.count).trimmingCharacters(in: .whitespaces)
        if base.isEmpty { return title.lowercased() }
    }
    return base.trimmingCharacters(in: .whitespaces).lowercased()
}

// MARK: - Persistence keys

/// UserDefaults keys for non-secret settings. Tokens and secrets live in
/// the Keychain under `KeychainKeys`.
nonisolated enum SettingsKeys {
    static let useMediaKeys = "useMediaKeys"
    /// JSON-encoded [PlexServer]. `plexServerURL` remains only so older
    /// single-server setups can be migrated by PlexServerStore.
    static let plexServers = "plexServers"
    static let plexServerURL = "plexServerURL"
    static let plexSelectedLibraries = "plexSelectedLibraries"
    static let jellyfinServerURL = "jellyfinServerURL"
    static let jellyfinUserID = "jellyfinUserID"
    static let jellyfinUsername = "jellyfinUsername"
    static let jellyfinSelectedLibraries = "jellyfinSelectedLibraries"

    static let tvTopLevel = "tvTopLevel"
    static let musicTopLevel = "musicTopLevel"
    static let movieAutoContinue = "movieAutoContinue"
    static let tvAutoContinue = "tvAutoContinue"
    static let musicAutoContinue = "musicAutoContinue"
    static let cacheArtwork = "cacheArtwork"
    static let simpleVisuals = "simpleVisuals"
    static let playbackProgress = "playbackProgress"
    static let continueTimeout = "continueTimeout"
    static let continueMusic = "continueMusic"
    static let downloadsEnabled = "downloadsEnabled"
    static let playerUISize = "playerUISize"
    static let playerMode = "playerMode"
    static let richMedia = "richMedia"
    static let movieSort = "movieSort"
    static let tvSort = "tvSort"
    static let musicSort = "musicSort"
    static let movieSortDirection = "movieSortDirection"
    static let tvSortDirection = "tvSortDirection"
    static let musicSortDirection = "musicSortDirection"

    static func sectionEnabled(_ section: MenuSection) -> String {
        "sectionEnabled_\(section.rawValue)"
    }

    static func downloadFolderBookmark(_ type: MediaType) -> String {
        "downloadFolderBookmark_\(type.rawValue)"
    }

    static func downloadFolderPath(_ type: MediaType) -> String {
        "downloadFolderPath_\(type.rawValue)"
    }

    static func downloadLimitGB(_ type: MediaType) -> String {
        "downloadLimitGB_\(type.rawValue)"
    }

    static func downloadLevelEnabled(_ level: DownloadLevel) -> String {
        "downloadLevel_\(level.rawValue)"
    }

    static func libraryFolderBookmark(_ type: MediaType) -> String {
        "libraryFolderBookmark_\(type.rawValue)"
    }

    static func libraryFolderPath(_ type: MediaType) -> String {
        "libraryFolderPath_\(type.rawValue)"
    }

    static let downloadIndicatorsEnabled = "downloadIndicatorsEnabled"
    static let tmdbAPIKey = "tmdbAPIKey"

    static let movieLocalFirst = "movieLocalFirst"
    static let tvLocalFirst = "tvLocalFirst"
    static let musicLocalFirst = "musicLocalFirst"
}

/// Keychain item names for secrets.
enum KeychainKeys {
    /// Legacy single-server token; migrated to a per-server item.
    static let plexToken = "plexToken"
    /// plex.tv account token from Sign In With Plex, used for server discovery.
    static let plexAccountToken = "plexAccountToken"

    static func plexServerToken(_ serverID: String) -> String {
        "plexToken_\(serverID)"
    }
    static let jellyfinToken = "jellyfinToken"
    static let traktAccessToken = "traktAccessToken"
    static let traktRefreshToken = "traktRefreshToken"
    static let lastfmSessionKey = "lastfmSessionKey"
}
