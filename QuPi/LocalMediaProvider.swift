#if os(macOS)
import Foundation

/// Serves locally downloaded media from the per-type folders configured in
/// Settings → Data → Downloads. Items carry `source: .local` for routing
/// but keep their original `id` values so they de-duplicate against server
/// items in the catalog (same id → server poster gets the green tick;
/// local item only appears when no server counterpart is present).
struct LocalMediaProvider: MediaProvider {
    var tvTopLevel: TVTopLevel = .series
    var musicTopLevel: MusicTopLevel = .album

    var source: MediaSource { .local }

    // MARK: - MediaProvider

    func items(for type: MediaType) async throws -> [MediaItem] {
        let entries = DownloadManager.libraryIndexedEntries(for: type) + DownloadManager.indexedEntries(for: type)
        var indexedIDs = Set<String>()
        let indexed = entries.compactMap { entry -> MediaItem? in
            guard entry.filename != nil || entry.item.kind.isExpandable else { return nil }
            if !indexedIDs.insert(entry.item.id).inserted { return nil }
            return localised(entry.item, filename: entry.filename)
        }
        let dropped = unindexedItems(for: type, excluding: indexedIDs)
        let top = topLevel(of: indexed + dropped, type: type)
        
        // Enrich items with extracted offline metadata before returning
        return enrich(items: top, allEntries: entries)
    }

    func children(of item: MediaItem) async throws -> [MediaItem] {
        let entries = DownloadManager.libraryIndexedEntries(for: item.type) + DownloadManager.indexedEntries(for: item.type)
        var indexedIDs = Set<String>()
        let kids = entries.compactMap { entry -> MediaItem? in
            guard (entry.filename != nil || entry.item.kind.isExpandable), entry.item.parentID == item.id else { return nil }
            if !indexedIDs.insert(entry.item.id).inserted { return nil }
            return localised(entry.item, filename: entry.filename)
        }
        
        // Enrich children with extracted offline metadata before returning
        return enrich(items: kids, allEntries: entries)
    }

    func playlists() async throws -> [MediaItem] {
        let entries = DownloadManager.libraryIndexedEntries(for: .music) + DownloadManager.indexedEntries(for: .music)
        var indexedIDs = Set<String>()
        return entries.compactMap { entry -> MediaItem? in
            guard entry.item.kind == .playlist else { return nil }
            if !indexedIDs.insert(entry.item.id).inserted { return nil }
            return localised(entry.item, filename: entry.filename)
        }
    }

    func streamURL(for item: MediaItem) async throws -> URL {
        guard let url = DownloadManager.shared.localLibraryURL(for: item) else {
            throw URLError(.fileDoesNotExist)
        }
        return url
    }

    // MARK: - Content check

    /// True when at least one library folder has media files, used by
    /// AppState to decide whether to register this provider.
    var hasContent: Bool {
        MediaType.allCases.contains { DownloadManager.mediaCounts(for: $0).leaves > 0 }
    }

    // MARK: - Enrichment (Offline Metadata Recovery)
    
    /// Dynamically recalculates episode counts for Seasons and extracts missing year metadata
    /// for synthesized TV Shows while in offline mode.
    private func enrich(items: [MediaItem], allEntries: [DownloadIndexEntry]) -> [MediaItem] {
        return items.map { item in
            var enriched = item
            
            // 1. Season: Dynamically calculate the offline episode count
            if enriched.kind == .season {
                let count = allEntries.filter { $0.item.parentID == enriched.id && $0.item.kind == .episode && $0.filename != nil }.count
                if count > 0 {
                    enriched.subtitle = "\(count) episode\(count == 1 ? "" : "s")"
                }
            }
            
            // 2. Show: Recover missing year metadata from child episodes
            if enriched.kind == .show && (enriched.subtitle == nil || enriched.subtitle?.isEmpty == true) {
                let episode = allEntries.first { entry in
                    guard entry.item.kind == .episode else { return false }
                    if entry.item.attributes["grandparentRatingKey"] == enriched.id { return true }
                    if entry.item.parentKind == .season, let seasonID = entry.item.parentID {
                        if let seasonEntry = allEntries.first(where: { $0.item.id == seasonID }) {
                            return seasonEntry.item.parentID == enriched.id
                        }
                    }
                    return false
                }?.item
                
                if let ep = episode, let year = ep.attributes["grandparentYear"] ?? ep.attributes["year"] {
                    enriched.subtitle = year
                }
            }
            
            return enriched
        }
    }

    // MARK: - Helpers

    private func localArtworkURL(in folder: URL, stem: String?) -> URL? {
        let candidates: [String]
        if let stem {
            candidates = ["\(stem).jpg", "\(stem).png", "\(stem).jpeg"]
        } else {
            candidates = ["poster.jpg", "poster.png", "poster.jpeg"]
        }
        for candidate in candidates {
            let url = folder.appending(path: candidate)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func localArtworkURL(filename: String?, type: MediaType,
                                 kind: MediaKind? = nil, title: String? = nil,
                                 parentTitle: String? = nil) -> URL? {
        let folders = [DownloadManager.resolvedFolder(for: type), DownloadManager.resolvedLibraryFolder(for: type)].compactMap { $0 }
        for folder in folders {
            if let filename {
                let fileURL = folder.appending(path: filename)
                let baseDir = fileURL.deletingLastPathComponent()
                let stem = fileURL.deletingPathExtension().lastPathComponent
                if let url = localArtworkURL(in: baseDir, stem: stem) { return url }
                if let url = localArtworkURL(in: baseDir, stem: nil) { return url }
            } else if kind == .show, let title {
                // Sibling naming: ShowTitle.jpg sits next to show folder, inside type root.
                if let url = localArtworkURL(in: folder, stem: sanitize(title)) { return url }
                // Fallback: poster.* inside the show folder.
                if let url = localArtworkURL(in: folder.appending(path: sanitize(title)), stem: nil) { return url }
            } else if kind == .season, let title {
                // Sibling naming: SeasonTitle.jpg sits next to season folder, inside show folder.
                if let parent = parentTitle {
                    let showDir = folder.appending(path: sanitize(parent))
                    if let url = localArtworkURL(in: showDir, stem: sanitize(title)) { return url }
                    // Fallback: poster.* inside the season folder.
                    if let url = localArtworkURL(in: showDir.appending(path: sanitize(title)), stem: nil) { return url }
                } else {
                    if let url = localArtworkURL(in: folder, stem: sanitize(title)) { return url }
                    if let url = localArtworkURL(in: folder.appending(path: sanitize(title)), stem: nil) { return url }
                }
            }
        }
        return nil
    }

    private func sanitize(_ s: String) -> String {
        var r = s.replacing("/", with: "-").replacing(":", with: "-")
        while r.hasPrefix(".") { r = String(r.dropFirst()) }
        return r.isEmpty ? "Unknown" : r
    }

    private func localised(_ item: MediaItem, filename: String?) -> MediaItem {
        var m = item
        m.source = .local
        if let poster = localArtworkURL(filename: filename, type: item.type,
                                        kind: item.kind, title: item.title,
                                        parentTitle: item.parentTitle) {
            m.posterURL = poster
        }
        return m
    }

    /// Files present in the library folder that have no index entry (content dropped
    /// in manually). Synthesises minimal MediaItems so they appear in the UI.
    private func unindexedItems(for type: MediaType, excluding known: Set<String>) -> [MediaItem] {
        guard let folder = DownloadManager.resolvedLibraryFolder(for: type) else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        )) ?? []
        let scanner = LocalLibraryScanner(type: type, folder: folder)
        return contents.compactMap { url -> MediaItem? in
            guard !url.lastPathComponent.hasPrefix("."),
                  DownloadManager.mediaExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            let id = "local-\(name)"
            guard !known.contains(id) else { return nil }
            let kind: MediaKind = switch type {
            case .movies: .movie
            case .tvShows: .episode
            case .music: .track
            }
            let title: String = switch type {
            case .tvShows: scanner.parseEpisode(from: name).title
            default: name
            }
            return MediaItem(id: id, source: .local, type: type, kind: kind, title: title)
        }
    }

    /// Returns the appropriate top-level items given the configured navigation
    /// top-level preference, mirroring server provider behaviour.
    private func topLevel(of items: [MediaItem], type: MediaType) -> [MediaItem] {
        switch type {
        case .movies:
            return items.filter { $0.kind == .movie }
        case .tvShows:
            if tvTopLevel == .series, items.contains(where: { $0.kind == .show }) {
                return items.filter { $0.kind == .show }
            }
            if items.contains(where: { $0.kind == .season }) {
                return items.filter { $0.kind == .season }
            }
            return items.filter { $0.kind == .episode }
        case .music:
            if musicTopLevel == .artist, items.contains(where: { $0.kind == .artist }) {
                return items.filter { $0.kind == .artist }
            }
            if items.contains(where: { $0.kind == .album }) {
                return items.filter { $0.kind == .album }
            }
            if items.contains(where: { $0.kind == .playlist }) {
                return items.filter { $0.kind == .playlist }
            }
            return items.filter { $0.kind == .track }
        }
    }
}
#endif // os(macOS)
