import Foundation

struct JellyfinConfiguration {
    var serverURL: URL
    var token: String
    var userID: String
}

struct JellyfinLibrary: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    /// Jellyfin collection type: "movies", "tvshows", or "music".
    let collectionType: String?

    var mediaType: MediaType? {
        switch collectionType {
        case "movies": .movies
        case "tvshows": .tvShows
        case "music": .music
        default: nil
        }
    }
}

/// Minimal Jellyfin server client, mirroring PlexClient's role. Authenticates
/// with username/password to obtain an access token and user ID.
struct JellyfinClient {
    static let deviceID = "QuPiMenuBar"

    let config: JellyfinConfiguration

    private static func authorizationHeader(token: String?) -> String {
        var header = #"MediaBrowser Client="QuPi", Device="Mac", DeviceId="\#(deviceID)", Version="1.0""#
        if let token {
            header += #", Token="\#(token)""#
        }
        return header
    }

    private func request(path: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(
            url: config.serverURL.appending(path: path),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = (components.queryItems ?? []) + query
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.authorizationHeader(token: config.token), forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - Authentication

    /// Signs in with username/password; the returned token and user ID are
    /// what a JellyfinConfiguration needs.
    static func authenticate(serverURL: URL, username: String, password: String) async throws -> (token: String, userID: String) {
        struct Response: Decodable {
            struct User: Decodable { let Id: String }
            let AccessToken: String
            let User: User
        }
        var request = URLRequest(url: serverURL.appending(path: "/Users/AuthenticateByName"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authorizationHeader(token: nil), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["Username": username, "Pw": password])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.userAuthenticationRequired)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return (decoded.AccessToken, decoded.User.Id)
    }

    // MARK: - Catalog

    func libraries() async throws -> [JellyfinLibrary] {
        struct Item: Decodable {
            let Id: String
            let Name: String
            let CollectionType: String?
        }
        struct Response: Decodable { let Items: [Item] }
        let (data, _) = try await URLSession.shared.data(
            for: request(path: "/Users/\(config.userID)/Views")
        )
        return try JSONDecoder().decode(Response.self, from: data).Items.map {
            JellyfinLibrary(id: $0.Id, name: $0.Name, collectionType: $0.CollectionType)
        }
    }

    private struct UserData: Decodable {
        let PlayCount: Int?
    }

    private struct PersonRef: Decodable {
        let Id: String?
        let Name: String?
        let personType: String?

        enum CodingKeys: String, CodingKey {
            case Id, Name
            case personType = "Type"
        }
    }

    private struct Item: Decodable {
        let Id: String
        let Name: String
        let itemType: String?
        let ProductionYear: Int?
        let IndexNumber: Int?
        let ParentIndexNumber: Int?
        let Overview: String?
        let AlbumArtist: String?
        let SeriesName: String?
        let SeriesId: String?
        let SeasonId: String?
        let SeasonName: String?
        let AlbumId: String?
        let Album: String?
        let PremiereDate: String?
        let DateCreated: String?
        let UserData: UserData?
        let People: [PersonRef]?
        let ArtistItems: [PersonRef]?
        let Path: String?

        enum CodingKeys: String, CodingKey {
            case Id, Name, ProductionYear, IndexNumber, ParentIndexNumber, Overview, AlbumArtist
            case SeriesName, SeriesId, SeasonId, SeasonName, AlbumId, Album, PremiereDate
            case DateCreated, UserData, People, ArtistItems, Path
            case itemType = "Type"
        }
    }

    private struct ItemsResponse: Decodable { let Items: [Item] }

    private func queryItems(_ query: [URLQueryItem]) async throws -> [Item] {
        let (data, _) = try await URLSession.shared.data(for: request(
            path: "/Users/\(config.userID)/Items",
            query: query
        ))
        return try JSONDecoder().decode(ItemsResponse.self, from: data).Items
    }

    func items(inLibrary libraryID: String, type: MediaType, tvTopLevel: TVTopLevel, musicTopLevel: MusicTopLevel) async throws -> [MediaItem] {
        let (itemType, kind): (String, MediaKind) = switch type {
        case .movies: ("Movie", .movie)
        case .tvShows: tvTopLevel == .season ? ("Season", .season) : ("Series", .show)
        case .music: musicTopLevel == .artist ? ("MusicArtist", .artist) : ("MusicAlbum", .album)
        }
        let items = try await queryItems([
            URLQueryItem(name: "ParentId", value: libraryID),
            URLQueryItem(name: "IncludeItemTypes", value: itemType),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "Fields", value: "Overview,DateCreated,UserData"),
        ])
        return items.map { item in
            MediaItem(
                id: item.Id,
                source: .jellyfin,
                type: type,
                kind: kind,
                title: item.Name,
                // Season top level keeps the show visible via the subtitle.
                subtitle: item.SeriesName ?? item.AlbumArtist ?? item.ProductionYear.map(String.init),
                posterURL: imageURL(itemID: item.Id),
                streamURL: nil,
                summary: item.Overview,
                attributes: [
                    "releaseDate": item.PremiereDate ?? "",
                    "grandparentTitle": item.SeriesName ?? "",
                    "originalPath": item.Path ?? ""
                ],
                addedAt: item.DateCreated.flatMap {
                    try? Date($0, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
                },
                playCount: item.UserData?.PlayCount
            )
        }
    }

    /// Direct children of a container: a series' seasons, a season's
    /// episodes, an artist's albums, an album's or playlist's tracks.
    func children(of item: MediaItem) async throws -> [MediaItem] {
        // Albums aren't filesystem children of artists, so use the artist
        // relation rather than ParentId for that level. Playlists keep
        // their curated order via their dedicated endpoint's ParentId form.
        let query: [URLQueryItem] = if item.kind == .artist {
            [
                URLQueryItem(name: "ArtistIds", value: item.id),
                URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "SortBy", value: "PremiereDate,SortName"),
                URLQueryItem(name: "Fields", value: "Overview"),
            ]
        } else if item.kind == .playlist {
            [
                URLQueryItem(name: "ParentId", value: item.id),
                URLQueryItem(name: "Fields", value: "Overview"),
            ]
        } else {
            [
                URLQueryItem(name: "ParentId", value: item.id),
                URLQueryItem(name: "SortBy", value: "IndexNumber,SortName"),
                URLQueryItem(name: "Fields", value: "Overview"),
            ]
        }
        return try await queryItems(query).compactMap { entry in
            let kind: MediaKind? = switch entry.itemType {
            case "Movie": .movie
            case "Season": .season
            case "Episode": .episode
            case "MusicAlbum": .album
            case "Audio": .track
            default: nil
            }
            guard let kind else { return nil }
            // Playlists mix media types, so derive each child's type.
            let childType: MediaType = switch kind {
            case .movie: .movies
            case .season, .episode: .tvShows
            case .album, .track: .music
            default: item.type
            }
            let subtitle: String? = switch kind {
            case .episode: entry.IndexNumber.map { index in
                entry.ParentIndexNumber.map { "S\($0)E\(index)" } ?? "Episode \(index)"
            }
            case .track: entry.AlbumArtist
            default: entry.ProductionYear.map(String.init)
            }
            return MediaItem(
                id: entry.Id,
                source: .jellyfin,
                type: childType,
                kind: kind,
                title: entry.Name,
                subtitle: subtitle,
                posterURL: imageURL(itemID: entry.Id),
                streamURL: nil,
                summary: entry.Overview,
                parentID: item.id,
                parentKind: item.kind,
                parentTitle: item.title,
                parentPosterURL: item.posterURL,
                attributes: [
                    "originalPath": entry.Path ?? "",
                    "grandparentTitle": entry.SeriesName ?? "",
                    "grandparentRatingKey": entry.SeriesId ?? ""
                ]
            )
        }
    }

    /// The user's playlists.
    func playlists() async throws -> [MediaItem] {
        let items = try await queryItems([
            URLQueryItem(name: "IncludeItemTypes", value: "Playlist"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
        ])
        return items.map { entry in
            MediaItem(
                id: entry.Id,
                source: .jellyfin,
                type: .music,
                kind: .playlist,
                title: entry.Name,
                subtitle: nil,
                posterURL: imageURL(itemID: entry.Id),
                streamURL: nil,
                summary: entry.Overview
            )
        }
    }

    // MARK: - Deep search

    /// Server-wide search mapped to ancestor chains per the configured top
    /// levels, so matched tracks/episodes surface their artist/show.
    func deepSearch(_ query: String, type: MediaType, tvTopLevel: TVTopLevel, musicTopLevel: MusicTopLevel) async throws -> [[MediaItem]] {
        let includeTypes = switch type {
        case .movies: "Movie"
        case .tvShows: "Series,Season,Episode"
        case .music: "MusicArtist,MusicAlbum,Audio"
        }
        let results = try await queryItems([
            URLQueryItem(name: "SearchTerm", value: query),
            URLQueryItem(name: "IncludeItemTypes", value: includeTypes),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Limit", value: "50"),
        ])

        return results.compactMap { entry -> [MediaItem]? in
            func leaf(kind: MediaKind, type: MediaType, parent: MediaItem?) -> MediaItem? {
                ancestorItem(id: entry.Id, title: entry.Name, kind: kind, type: type, parent: parent)
            }
            switch (entry.itemType, type) {
            case ("Movie", .movies):
                return leaf(kind: .movie, type: .movies, parent: nil).map { [$0] }
            case ("Series", .tvShows) where tvTopLevel == .series:
                return leaf(kind: .show, type: .tvShows, parent: nil).map { [$0] }
            case ("Season", .tvShows):
                let show = tvTopLevel == .series
                    ? ancestorItem(id: entry.SeriesId, title: entry.SeriesName, kind: .show, type: .tvShows)
                    : nil
                guard let season = leaf(kind: .season, type: .tvShows, parent: show) else { return nil }
                return (show.map { [$0] } ?? []) + [season]
            case ("Episode", .tvShows):
                let show = tvTopLevel == .series
                    ? ancestorItem(id: entry.SeriesId, title: entry.SeriesName, kind: .show, type: .tvShows)
                    : nil
                guard let season = ancestorItem(id: entry.SeasonId, title: entry.SeasonName ?? "Season", kind: .season, type: .tvShows, parent: show),
                      let episode = leaf(kind: .episode, type: .tvShows, parent: season) else { return nil }
                return (show.map { [$0] } ?? []) + [season, episode]
            case ("MusicArtist", .music) where musicTopLevel == .artist:
                return leaf(kind: .artist, type: .music, parent: nil).map { [$0] }
            case ("MusicAlbum", .music):
                let artist = musicTopLevel == .artist
                    ? ancestorItem(id: entry.ArtistItems?.first?.Id, title: entry.AlbumArtist ?? entry.ArtistItems?.first?.Name, kind: .artist, type: .music)
                    : nil
                guard let album = leaf(kind: .album, type: .music, parent: artist) else { return nil }
                return (artist.map { [$0] } ?? []) + [album]
            case ("Audio", .music):
                let artist = musicTopLevel == .artist
                    ? ancestorItem(id: entry.ArtistItems?.first?.Id, title: entry.AlbumArtist ?? entry.ArtistItems?.first?.Name, kind: .artist, type: .music)
                    : nil
                guard let album = ancestorItem(id: entry.AlbumId, title: entry.Album ?? "Album", kind: .album, type: .music, parent: artist),
                      let track = leaf(kind: .track, type: .music, parent: album) else { return nil }
                return (artist.map { [$0] } ?? []) + [album, track]
            default:
                return nil
            }
        }
    }

    // MARK: - Auto-continue queries

    private func itemDetail(id: String) async throws -> Item {
        let (data, _) = try await URLSession.shared.data(
            for: request(path: "/Users/\(config.userID)/Items/\(id)")
        )
        return try JSONDecoder().decode(Item.self, from: data)
    }

    private func movieItem(from entry: Item) -> MediaItem {
        MediaItem(
            id: entry.Id,
            source: .jellyfin,
            type: .movies,
            kind: .movie,
            title: entry.Name,
            subtitle: entry.ProductionYear.map(String.init),
            posterURL: imageURL(itemID: entry.Id),
            streamURL: nil,
            summary: entry.Overview,
            attributes: [
                "releaseDate": entry.PremiereDate ?? "",
                "originalPath": entry.Path ?? ""
            ]
        )
    }

    /// Picks the next movie per the criterion using the item's People
    /// credits and person-filtered library queries.
    func nextMovie(after item: MediaItem, by criterion: MovieAutoContinue) async throws -> MediaItem? {
        guard criterion != .off else { return nil }
        let detail = try await itemDetail(id: item.id)
        let currentDate = detail.PremiereDate ?? ""

        var candidates: [MediaItem]
        switch criterion {
        case .off:
            return nil
        case .inSequence:
            let all = try await queryItems([
                URLQueryItem(name: "IncludeItemTypes", value: "Movie"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "Fields", value: "PremiereDate"),
            ]).map(movieItem(from:))
            let base = franchiseBaseTitle(item.title)
            candidates = all.filter { franchiseBaseTitle($0.title) == base }
        case .byDirector, .byLeadActor:
            let person: PersonRef? = if criterion == .byDirector {
                detail.People?.first { $0.personType == "Director" }
            } else {
                detail.People?.first { $0.personType == "Actor" }
            }
            guard let personID = person?.Id else { return nil }
            candidates = try await queryItems([
                URLQueryItem(name: "PersonIds", value: personID),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "Fields", value: "PremiereDate"),
            ]).map(movieItem(from:))
        }

        candidates.removeAll { $0.id == item.id }
        candidates.sort { ($0.attributes["releaseDate"] ?? "") < ($1.attributes["releaseDate"] ?? "") }
        return candidates.first { ($0.attributes["releaseDate"] ?? "") > currentDate } ?? candidates.first
    }

    /// A random other track by the same artist.
    func randomTrack(sameArtistAs item: MediaItem) async throws -> MediaItem? {
        let detail = try await itemDetail(id: item.id)
        guard let artistID = detail.ArtistItems?.first?.Id else { return nil }
        let tracks = try await queryItems([
            URLQueryItem(name: "ArtistIds", value: artistID),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "Random"),
            URLQueryItem(name: "Limit", value: "25"),
        ])
        guard let pick = tracks.filter({ $0.Id != item.id }).randomElement() else { return nil }
        return MediaItem(
            id: pick.Id,
            source: .jellyfin,
            type: .music,
            kind: .track,
            title: pick.Name,
            subtitle: pick.AlbumArtist,
            posterURL: imageURL(itemID: pick.Id),
            streamURL: nil,
            summary: pick.Overview
        )
    }

    nonisolated func imageURL(itemID: String) -> URL {
        var components = URLComponents(
            url: config.serverURL.appending(path: "/Items/\(itemID)/Images/Primary"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "maxWidth", value: "400"),
            URLQueryItem(name: "quality", value: "90"),
        ]
        return components.url!
    }

    private nonisolated func ancestorItem(id: String?, title: String?, kind: MediaKind, type: MediaType, parent: MediaItem? = nil) -> MediaItem? {
        guard let id, let title else { return nil }
        return MediaItem(
            id: id,
            source: .jellyfin,
            type: type,
            kind: kind,
            title: title,
            posterURL: imageURL(itemID: id),
            parentID: parent?.id,
            parentKind: parent?.kind
        )
    }

    /// Original-file download URL using Jellyfin's dedicated download endpoint.
    func downloadURL(itemID: String) -> URL {
        var components = URLComponents(
            url: config.serverURL.appending(path: "/Items/\(itemID)/Download"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "api_key", value: config.token)]
        return components.url!
    }

    // MARK: - Streaming

    /// Leaf items stream directly; containers fall back to their first
    /// playable descendant (e.g. playing a whole show from search).
    func resolveStreamURL(for item: MediaItem) async throws -> URL {
        switch item.kind {
        case .movie, .episode:
            return videoStreamURL(itemID: item.id)
        case .track:
            return audioStreamURL(itemID: item.id)
        case .show, .season:
            let episodeID = try await firstChildID(parentID: item.id, itemType: "Episode")
            return videoStreamURL(itemID: episodeID ?? item.id)
        case .artist, .album, .playlist:
            let trackID = try await firstChildID(parentID: item.id, itemType: "Audio")
            return audioStreamURL(itemID: trackID ?? item.id)
        }
    }

    private func firstChildID(parentID: String, itemType: String) async throws -> String? {
        struct Item: Decodable { let Id: String }
        struct Response: Decodable { let Items: [Item] }
        let (data, _) = try await URLSession.shared.data(for: request(
            path: "/Users/\(config.userID)/Items",
            query: [
                URLQueryItem(name: "ParentId", value: parentID),
                URLQueryItem(name: "IncludeItemTypes", value: itemType),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "SortBy", value: "ParentIndexNumber,IndexNumber,SortName"),
                URLQueryItem(name: "Limit", value: "1"),
            ]
        ))
        return try JSONDecoder().decode(Response.self, from: data).Items.first?.Id
    }

    private func videoStreamURL(itemID: String) -> URL {
        var components = URLComponents(
            url: config.serverURL.appending(path: "/Videos/\(itemID)/master.m3u8"),
            resolvingAgainstBaseURL: false
        )!
        // Providing codec capabilities encourages Jellyfin to direct-stream (remux) rather than
        // transcode. Direct-stream produces a VOD-type HLS manifest with #EXT-X-ENDLIST, which
        // gives AVFoundation a fully populated seekableTimeRanges — required for the system PiP
        // scrubber to be interactive.
        components.queryItems = [
            URLQueryItem(name: "api_key", value: config.token),
            URLQueryItem(name: "MediaSourceId", value: itemID),
            URLQueryItem(name: "DeviceId", value: Self.deviceID),
            URLQueryItem(name: "VideoCodec", value: "h264,hevc,av1,vp9"),
            URLQueryItem(name: "AudioCodec", value: "aac,mp3,ac3,eac3,alac,flac,pcm"),
            URLQueryItem(name: "EnableDirectPlay", value: "false"),
            URLQueryItem(name: "EnableDirectStream", value: "true"),
        ]
        return components.url!
    }

    private func audioStreamURL(itemID: String) -> URL {
        var components = URLComponents(
            url: config.serverURL.appending(path: "/Audio/\(itemID)/universal"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: config.token),
            URLQueryItem(name: "UserId", value: config.userID),
            URLQueryItem(name: "DeviceId", value: Self.deviceID),
            URLQueryItem(name: "Container", value: "mp3,aac,m4a|aac,flac,wav"),
            URLQueryItem(name: "TranscodingContainer", value: "ts"),
            URLQueryItem(name: "TranscodingProtocol", value: "hls"),
            URLQueryItem(name: "AudioCodec", value: "aac"),
        ]
        return components.url!
    }

    // MARK: - Playback reporting

    /// Reports position to the server so resume points stay in sync.
    /// Positions are in ticks (100ns units).
    func reportPlayback(itemID: String, state: PlaybackState, positionSeconds: Double) async throws {
        let path = switch state {
        case .playing: "/Sessions/Playing/Progress"
        case .paused: "/Sessions/Playing/Progress"
        case .started: "/Sessions/Playing"
        case .stopped: "/Sessions/Playing/Stopped"
        }
        var request = request(path: path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "ItemId": itemID,
            "PositionTicks": Int(positionSeconds * 10_000_000),
            "IsPaused": state == .paused,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await URLSession.shared.data(for: request)
    }
}

/// MediaProvider backed by a Jellyfin server, restricted to the libraries
/// selected in Settings (or all libraries when none are selected).
struct JellyfinMediaProvider: MediaProvider {
    let client: JellyfinClient
    let selectedLibraryIDs: Set<String>
    var tvTopLevel: TVTopLevel = .series
    var musicTopLevel: MusicTopLevel = .album

    var source: MediaSource { .jellyfin }

    func children(of item: MediaItem) async throws -> [MediaItem] {
        try await client.children(of: item)
    }

    func playlists() async throws -> [MediaItem] {
        try await client.playlists()
    }

    func deepSearch(_ query: String, type: MediaType) async throws -> [[MediaItem]] {
        try await client.deepSearch(query, type: type, tvTopLevel: tvTopLevel, musicTopLevel: musicTopLevel)
    }

    func items(for type: MediaType) async throws -> [MediaItem] {
        let libraries = try await client.libraries().filter { library in
            library.mediaType == type
                && (selectedLibraryIDs.isEmpty || selectedLibraryIDs.contains(library.id))
        }
        var all: [MediaItem] = []
        for library in libraries {
            all += try await client.items(
                inLibrary: library.id,
                type: type,
                tvTopLevel: tvTopLevel,
                musicTopLevel: musicTopLevel
            )
        }
        return all
    }

    func streamURL(for item: MediaItem) async throws -> URL {
        try await client.resolveStreamURL(for: item)
    }

    func downloadURL(for item: MediaItem) async throws -> URL {
        client.downloadURL(itemID: item.id)
    }

    func nextMovie(after item: MediaItem, by criterion: MovieAutoContinue) async throws -> MediaItem? {
        try await client.nextMovie(after: item, by: criterion)
    }

    func randomTrack(sameArtistAs item: MediaItem) async throws -> MediaItem? {
        try await client.randomTrack(sameArtistAs: item)
    }
}
