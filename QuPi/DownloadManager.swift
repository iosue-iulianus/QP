#if os(macOS)
import AppKit
import Observation

/// One entry in the per-type download index.
struct DownloadIndexEntry: Codable {
    let item: MediaItem
    /// Filename (relative to the type's folder). `nil` for container entries
    /// written after all descendants of a batch download succeed.
    let filename: String?
}

/// A request from DownloadManager for the UI to answer before transcoding.
struct TranscodePromptRequest {
    let item: MediaItem
    let preset: TranscodePreset?
    let continuation: CheckedContinuation<TranscodePreset?, Never>?
}

/// Limits concurrent hardware HEVC encode sessions to the number of dedicated media
/// engines on this device. Callers `try await waitForSlot()` before starting a transcode
/// and `await release()` when done. Throws `CancellationError` while waiting if the
/// calling task is cancelled.
private actor TranscodePool {
    private var active: Int = 0
    private let capacity: Int

    init(capacity: Int) { self.capacity = max(1, capacity) }

    func waitForSlot() async throws {
        while active >= capacity {
            try await Task.sleep(for: .milliseconds(200))
        }
        active += 1
    }

    func release() {
        active = max(0, active - 1)
    }
}

/// Downloads media to the per-type folders chosen in Settings → Data,
/// enforcing the per-type storage allocation. Folder access persists across
/// launches via security-scoped bookmarks. A JSON index sidecar
/// (`.qp-downloads.json`) tracks what has been downloaded so the app can
/// serve it as a local library and prefer local files for playback.
@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    /// IDs of items downloading; used by `PosterCell` to know if a download is active.
    var downloadingIDs: Set<String> = []
    
    /// Full items downloading; drives the Downloading section in the menu bar.
    var downloadingItems: [MediaItem] = []
    
    /// Tracks download progress (0.0 to 1.0) for active downloads by item ID.
    var downloadProgress: [String: Double] = [:]
    
    /// Holds items waiting for the user to respond to the Convert prompt
    var pendingPrompts: [String: TranscodePromptRequest] = [:]
    
    var transcodeQueue: [TranscodeQueueEntry] = []
    /// Active transcode tasks keyed by item ID; supports concurrent cancellation.
    private var activeTasks: [String: Task<URL?, Never>] = [:]
    private let transcodePool = TranscodePool(capacity: VideoTranscoder.hardwareEncodeEngineCount())

    /// In-memory caches of downloaded item IDs per type, populated on launch and
    /// updated on each download completion. Used by sortedItems for O(1) Local First
    /// checks instead of reading the JSON index from disk on every sort call.
    var downloadedMovieIDs: Set<String> = []
    var downloadedTVShowIDs: Set<String> = []
    var downloadedMusicIDs: Set<String> = []

    /// Returns active download or transcode progress (0.0 to 1.0) for an item ID.
        func activeProgress(for itemID: String) -> Double? {
            // Transcode progress takes precedence
            if let entry = transcodeQueue.first(where: { $0.id == itemID }) {
                return Double(entry.progress)
            }
            if let progress = downloadProgress[itemID] {
                return progress
            }
            return nil
        }

    /// Evaluates whether an already downloaded item exceeds the Transcode threshold
    /// and the user has Prompted mode enabled.
    func isEligibleForPromptedTranscode(_ item: MediaItem) -> Bool {
        guard isDownloaded(item), item.type != .music else { return false }
        
        let modeRaw = UserDefaults.standard.string(forKey: "transcodeMode") ?? "Automatic"
        guard modeRaw == "Prompted" else { return false }
        
        let thresholdRaw = UserDefaults.standard.string(forKey: SettingsKeys.transcodeThreshold(item.type)) ?? ""
        guard let threshold = TranscodeThreshold(rawValue: thresholdRaw),
              threshold != .disabled,
              let thresholdBytes = threshold.bytes else { return false }
        
        guard let url = localURL(for: item),
              let fileSize = try? url.resourceValues(forKeys: [.totalFileSizeKey]).totalFileSize else { return false }
              
        return Int64(fileSize) >= thresholdBytes
    }

    /// Resolves a pending transcode prompt with the user's decision.
    func resolvePrompt(for itemID: String, convert: Bool, preset: TranscodePreset?) {
        if let prompt = pendingPrompts.removeValue(forKey: itemID) {
            if let continuation = prompt.continuation {
                // Resume the suspended auto-download pipeline
                continuation.resume(returning: convert ? preset : nil)
            } else if convert, let preset = preset {
                // Manually trigger a transcode for an already downloaded file
                Task {
                    await forceTranscode(item: prompt.item, preset: preset)
                }
            }
        }
    }

    // MARK: - Init / folder lifetime access

    private var openedFolders: [MediaType: URL] = [:]
    private var openedLibraryFolders: [MediaType: URL] = [:]

    private init() {
        for type in MediaType.allCases {
            refreshFolderAccess(for: type)
            refreshLibraryFolderAccess(for: type)
        }
        cleanUpOrphans()
        cleanUpTranscodeTemps()
        populateDownloadedIDCache()
        restorePendingTranscodes()
        observeTermination()
    }

    private func observeTermination() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppTermination()
        }
    }

    private func handleAppTermination() {
        let behaviorRaw = UserDefaults.standard.string(forKey: SettingsKeys.queueOnClose)
            ?? QueueOnCloseBehavior.abandonQueue.rawValue
        guard QueueOnCloseBehavior(rawValue: behaviorRaw) == .keepQueue,
              !transcodeQueue.isEmpty else { return }
        let pending = transcodeQueue.map { SavedPendingTranscode(itemID: $0.id, mediaType: $0.mediaType) }
        if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: SettingsKeys.savedTranscodeQueue)
        }
    }

    private func populateDownloadedIDCache() {
        for type in MediaType.allCases {
            guard let folder = Self.resolvedFolder(for: type) else { continue }
            let index = Self.readIndexFromFolder(folder)
            let ids = Set(index.values.compactMap { entry -> String? in
                guard let filename = entry.filename else { return entry.item.id }
                return FileManager.default.fileExists(atPath: folder.appending(path: filename).path) ? entry.item.id : nil
            })
            setDownloadedIDs(ids, for: type)
        }
    }

    private func setDownloadedIDs(_ ids: Set<String>, for type: MediaType) {
        switch type {
        case .movies: downloadedMovieIDs = ids
        case .tvShows: downloadedTVShowIDs = ids
        case .music: downloadedMusicIDs = ids
        }
    }

    private func cleanUpTranscodeTemps() {
        for type in MediaType.allCases {
            guard let folder = Self.resolvedFolder(for: type),
                  let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".transcoding.tmp") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func restorePendingTranscodes() {
        guard let data = UserDefaults.standard.data(forKey: SettingsKeys.savedTranscodeQueue),
              let pending = try? JSONDecoder().decode([SavedPendingTranscode].self, from: data),
              !pending.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: SettingsKeys.savedTranscodeQueue)
        // Launch all items concurrently; TranscodePool limits actual encode concurrency.
        for entry in pending {
            guard let folder = Self.resolvedFolder(for: entry.mediaType) else { continue }
            let index = Self.readIndexFromFolder(folder)
            guard let indexEntry = index[entry.itemID],
                  let filename = indexEntry.filename else { continue }
            let fileURL = folder.appending(path: filename)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

            let task = Task<URL?, Never> { [weak self] in
                await self?.maybeTranscode(item: indexEntry.item, fileURL: fileURL, folder: folder)
            }
            activeTasks[entry.itemID] = task

            let itemID = entry.itemID
            Task { [weak self] in
                if let url = await task.value {
                    let newRelative = String(url.path.dropFirst(folder.path.count + 1))
                    var updatedIndex = Self.readIndexFromFolder(folder)
                    updatedIndex[itemID] = DownloadIndexEntry(item: indexEntry.item, filename: newRelative)
                    Self.writeIndex(updatedIndex, to: folder)
                }
                self?.activeTasks.removeValue(forKey: itemID)
            }
        }
    }

    private func cleanUpOrphans() {
        for type in MediaType.allCases {
            guard let folder = Self.resolvedFolder(for: type) else { continue }
            var index = Self.readIndexFromFolder(folder)
            var dirty = false

            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil
            )) ?? []
            for file in files where file.pathExtension.lowercased() == "m3u8" {
                try? FileManager.default.removeItem(at: file)
            }

            for (id, entry) in index {
                guard let filename = entry.filename else { continue }
                let dest = folder.appending(path: filename)
                if !FileManager.default.fileExists(atPath: dest.path) {
                    index.removeValue(forKey: id)
                    dirty = true
                }
            }
            if dirty { Self.writeIndex(index, to: folder) }
        }
    }

    private func refreshFolderAccess(for type: MediaType) {
        if let old = openedFolders[type] {
            old.stopAccessingSecurityScopedResource()
            openedFolders[type] = nil
        }
        if let folder = Self.resolvedFolder(for: type),
           folder.startAccessingSecurityScopedResource() {
            openedFolders[type] = folder
        }
    }

    private func refreshLibraryFolderAccess(for type: MediaType) {
        if let old = openedLibraryFolders[type] {
            old.stopAccessingSecurityScopedResource()
            openedLibraryFolders[type] = nil
        }
        if let folder = Self.resolvedLibraryFolder(for: type),
           folder.startAccessingSecurityScopedResource() {
            openedLibraryFolders[type] = folder
        }
    }

    // MARK: - Folder configuration

    static func setFolder(_ url: URL, for type: MediaType) {
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
            UserDefaults.standard.set(bookmark, forKey: SettingsKeys.downloadFolderBookmark(type))
            UserDefaults.standard.set(url.path, forKey: SettingsKeys.downloadFolderPath(type))
        }
        shared.refreshFolderAccess(for: type)
    }

    static func folderPath(for type: MediaType) -> String? {
        UserDefaults.standard.string(forKey: SettingsKeys.downloadFolderPath(type))
    }

    static func resolvedFolder(for type: MediaType) -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: SettingsKeys.downloadFolderBookmark(type)) else {
            return nil
        }
        var stale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    static func setLibraryFolder(_ url: URL, for type: MediaType) {
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
            UserDefaults.standard.set(bookmark, forKey: SettingsKeys.libraryFolderBookmark(type))
            UserDefaults.standard.set(url.path, forKey: SettingsKeys.libraryFolderPath(type))
        }
        shared.refreshLibraryFolderAccess(for: type)
    }

    static func libraryFolderPath(for type: MediaType) -> String? {
        UserDefaults.standard.string(forKey: SettingsKeys.libraryFolderPath(type))
    }

    static func resolvedLibraryFolder(for type: MediaType) -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: SettingsKeys.libraryFolderBookmark(type)) else {
            return nil
        }
        var stale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    static let mediaExtensions: Set<String> = [
        "mp4", "mkv", "mov", "m4v", "avi",
        "mp3", "m4a", "flac", "aiff", "wav",
    ]

    static func mediaCounts(for type: MediaType) -> (containers: Int, leaves: Int) {
        guard let folder = resolvedLibraryFolder(for: type) else { return (0, 0) }
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }

        var leafCount = 0
        var containerDirs: Set<String> = []

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            guard values?.isRegularFile == true,
                  mediaExtensions.contains(url.pathExtension.lowercased()) else { continue }
            leafCount += 1
            let rel = url.path.replacing(folder.path + "/", with: "")
            let components = rel.split(separator: "/")
            if components.count >= 2 {
                containerDirs.insert(String(components[0]))
            }
        }
        return (containerDirs.count, leafCount)
    }

    static func libraryIndexedEntries(for type: MediaType) -> [DownloadIndexEntry] {
        guard let folder = resolvedLibraryFolder(for: type) else { return [] }
        return Array(readIndexFromFolder(folder).values)
    }

    static func mergeLibraryIndex(_ entries: [DownloadIndexEntry], for type: MediaType) {
        guard let folder = resolvedLibraryFolder(for: type) else { return }
        var index = readIndexFromFolder(folder)
        for entry in entries {
            index[entry.item.id] = entry
        }
        writeIndex(index, to: folder)
    }

    func localLibraryURL(for item: MediaItem) -> URL? {
        guard let folder = Self.resolvedLibraryFolder(for: item.type) else { return nil }
        let index = Self.readIndexFromFolder(folder)
        guard let entry = index[item.id], let filename = entry.filename else { return nil }
        let fileURL = folder.appending(path: filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return fileURL
    }

    static func limitBytes(for type: MediaType) -> Int64 {
        let gigabytes = UserDefaults.standard.double(forKey: SettingsKeys.downloadLimitGB(type))
        return Int64(gigabytes * 1_000_000_000)
    }

    static func usageBytes(for type: MediaType) -> Int64 {
        guard let folder = resolvedFolder(for: type),
              let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .totalFileSizeKey],
                options: [.skipsHiddenFiles]
              ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .totalFileSizeKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileSize ?? 0)
        }
        return total
    }

    static func folderUsageDetails(for type: MediaType) -> (localBytes: Int64, downloadedBytes: Int64) {
        guard let folder = resolvedFolder(for: type) else { return (0, 0) }
        let total = usageBytes(for: type)
        var downloaded: Int64 = 0
        let index = readIndexFromFolder(folder)
        for entry in index.values {
            guard let filename = entry.filename else { continue }
            let fileURL = folder.appending(path: filename)
            if let values = try? fileURL.resourceValues(forKeys: [.totalFileSizeKey]),
               let size = values.totalFileSize {
                downloaded += Int64(size)
            }
        }
        return (max(0, total - downloaded), downloaded)
    }
    
    static func deleteDownloads(for type: MediaType) {
        guard let folder = resolvedFolder(for: type) else { return }
        var index = readIndexFromFolder(folder)
        
        for (id, entry) in index {
            if entry.item.source != .local {
                if let filename = entry.filename {
                    let fileURL = folder.appending(path: filename)
                    try? FileManager.default.removeItem(at: fileURL)
                }
                index.removeValue(forKey: id)
            }
        }
        writeIndex(index, to: folder)

        switch type {
        case .movies: shared.downloadedMovieIDs = []
        case .tvShows: shared.downloadedTVShowIDs = []
        case .music: shared.downloadedMusicIDs = []
        }

        if let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                if ext == "jpg" || ext == "jpeg" || ext == "png" {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }

        if let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            let dirs = enumerator.compactMap { element -> URL? in
                guard let url = element as? URL else { return nil }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                return isDir ? url : nil
            }
            for dir in dirs.sorted(by: { $0.path.count > $1.path.count }) {
                let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                if contents.isEmpty {
                    try? FileManager.default.removeItem(at: dir)
                }
            }
        }
    }
    
    static func clearDownloadedArtwork() {
        for type in MediaType.allCases {
            guard let folder = resolvedFolder(for: type) else { continue }
            if let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let fileURL as URL in enumerator {
                    let ext = fileURL.pathExtension.lowercased()
                    if ext == "jpg" || ext == "jpeg" || ext == "png" {
                        try? FileManager.default.removeItem(at: fileURL)
                    }
                }
            }
        }
    }

    static func isLevelEnabled(for kind: MediaKind) -> Bool {
        guard let level = DownloadLevel(kind: kind) else { return false }
        return UserDefaults.standard.bool(forKey: SettingsKeys.downloadLevelEnabled(level))
    }

    private static func indexURL(in folder: URL) -> URL {
        folder.appending(path: ".qp-downloads.json")
    }

    private static func readIndexFromFolder(_ folder: URL) -> [String: DownloadIndexEntry] {
        let url = indexURL(in: folder)
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: DownloadIndexEntry].self, from: data)) ?? [:]
    }

    private static func writeIndex(_ index: [String: DownloadIndexEntry], to folder: URL) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL(in: folder))
    }

    static func indexedEntries(for type: MediaType) -> [DownloadIndexEntry] {
        guard let folder = resolvedFolder(for: type) else { return [] }
        return Array(readIndexFromFolder(folder).values)
    }

    func isDownloaded(_ item: MediaItem) -> Bool {
        guard let folder = Self.resolvedFolder(for: item.type) else { return false }
        let index = Self.readIndexFromFolder(folder)
        guard let entry = index[item.id] else { return false }
        guard let filename = entry.filename else { return true }
        return FileManager.default.fileExists(
            atPath: folder.appending(path: filename).path
        )
    }

    func localURL(for item: MediaItem) -> URL? {
        guard let folder = Self.resolvedFolder(for: item.type) else { return nil }
        let index = Self.readIndexFromFolder(folder)
        guard let entry = index[item.id], let filename = entry.filename else { return nil }
        let fileURL = folder.appending(path: filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return fileURL
    }

    func download(_ item: MediaItem, appState: AppState) {
        guard !downloadingIDs.contains(item.id) else { return }
        Task {
            if item.kind.isExpandable {
                await downloadContainer(item, appState: appState)
            } else {
                await downloadLeaf(item, appState: appState, showAlerts: true)
            }
        }
    }

    private func downloadContainer(_ item: MediaItem, appState: AppState) async {
        guard Self.resolvedFolder(for: item.type) != nil else {
            Self.alert(
                title: "No Download Folder",
                message: "Choose a folder for \(item.type.rawValue) in Settings → Data → Downloads first."
            )
            return
        }
        downloadingIDs.insert(item.id)
        defer { downloadingIDs.remove(item.id) }

        let leavesWithAncestors = await appState.downloadLeaves(of: item)
        guard !leavesWithAncestors.isEmpty else { return }

        var failCount = 0
        for (leaf, ancestors) in leavesWithAncestors where !isDownloaded(leaf) {
            let ok = await downloadLeaf(leaf, ancestors: ancestors, appState: appState, showAlerts: false)
            if !ok { failCount += 1 }
        }

        let leaves = leavesWithAncestors.map(\.item)
        if leaves.allSatisfy({ isDownloaded($0) }),
           let folder = Self.resolvedFolder(for: item.type) {
            var index = Self.readIndexFromFolder(folder)
            index[item.id] = DownloadIndexEntry(item: item, filename: nil)
            Self.writeIndex(index, to: folder)
            
            if let firstLeaf = leavesWithAncestors.first,
               let leafEntry = index[firstLeaf.item.id],
               let filename = leafEntry.filename {
                let leafURL = folder.appending(path: filename)
                let leafFolder = leafURL.deletingLastPathComponent()

                switch item.kind {
                case .show:
                    let hasSeasonAncestor = firstLeaf.ancestors.contains(where: { $0.kind == .season })
                        || firstLeaf.item.parentKind == .season
                    let showFolder = hasSeasonAncestor ? leafFolder.deletingLastPathComponent() : leafFolder
                    let rootFolder = showFolder.deletingLastPathComponent()
                    if let freshURL = firstLeaf.ancestors.first(where: { $0.kind == .season })?.parentPosterURL {
                        await downloadArtwork(from: freshURL, stem: showFolder.lastPathComponent,
                                              destinationFolder: rootFolder)
                    } else {
                        await downloadArtwork(for: item, fileURL: nil, destinationFolder: rootFolder,
                                              name: showFolder.lastPathComponent)
                    }
                case .season:
                    let showFolder = leafFolder.deletingLastPathComponent()
                    await downloadArtwork(for: item, fileURL: nil, destinationFolder: showFolder,
                                          name: leafFolder.lastPathComponent)
                    if let showPosterURL = item.parentPosterURL {
                        let rootFolder = showFolder.deletingLastPathComponent()
                        await downloadArtwork(from: showPosterURL, stem: showFolder.lastPathComponent,
                                              destinationFolder: rootFolder)
                    }
                default:
                    await downloadArtwork(for: item, fileURL: nil, destinationFolder: leafFolder)
                }
            }
        }

        if failCount > 0 {
            Self.alert(
                title: "Some Downloads Failed",
                message: "\(failCount) of \(leavesWithAncestors.count) item(s) couldn't be downloaded."
            )
        }
    }

    @discardableResult
    private func downloadLeaf(
        _ item: MediaItem,
        ancestors: [MediaItem] = [],
        appState: AppState,
        showAlerts: Bool
    ) async -> Bool {
        guard !downloadingIDs.contains(item.id) else { return true }
        guard let folder = Self.resolvedFolder(for: item.type) else {
            if showAlerts {
                Self.alert(
                    title: "No Download Folder",
                    message: "Choose a folder for \(item.type.rawValue) in Settings → Data → Downloads first."
                )
            }
            return false
        }
        
        downloadingIDs.insert(item.id)
        downloadingItems.append(item)
        DispatchQueue.main.async { self.downloadProgress[item.id] = 0.0 }
        
        defer {
            downloadingIDs.remove(item.id)
            downloadingItems.removeAll { $0.id == item.id }
            DispatchQueue.main.async { self.downloadProgress.removeValue(forKey: item.id) }
        }
        
        do {
            let url = try await appState.downloadURL(for: item)

            let expected = await Self.expectedSize(of: url)
            let limit = Self.limitBytes(for: item.type)
            if limit > 0 {
                let usage = Self.usageBytes(for: item.type)
                if usage + max(expected, 0) > limit {
                    if showAlerts {
                        let formatter = ByteCountFormatter()
                        Self.alert(
                            title: "Not Enough Download Storage",
                            message: "\(item.title) needs \(formatter.string(fromByteCount: max(expected, 0))), but \(item.type.rawValue) downloads are limited to \(formatter.string(fromByteCount: limit)) and \(formatter.string(fromByteCount: usage)) is already used. Increase the allocation in Settings → Data or remove other downloads."
                        )
                    }
                    return false
                }
            }

            let (temporary, response) = try await downloadFileWithProgress(url: url, itemID: item.id)
            
            let fileExtension = response.suggestedFilename.flatMap { name -> String? in
                let ext = (name as NSString).pathExtension
                return ext.isEmpty ? nil : ext
            } ?? (url.pathExtension.isEmpty ? "media" : url.pathExtension)

            let relativePath = Self.relativePath(for: item, ancestors: ancestors, fileExtension: fileExtension)
            let destination = folder.appending(path: relativePath)

            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)

            var index = Self.readIndexFromFolder(folder)
            index[item.id] = DownloadIndexEntry(item: item, filename: relativePath)

            for ancestor in ancestors {
                if index[ancestor.id] == nil {
                    index[ancestor.id] = DownloadIndexEntry(item: ancestor, filename: nil)
                }
                if ancestor.kind == .season, ancestor.parentKind == .show,
                   let showID = ancestor.parentID, !showID.isEmpty,
                   let showTitle = ancestor.parentTitle, !showTitle.isEmpty {
                    if index[showID] == nil {
                        let showItem = MediaItem(id: showID, source: ancestor.source, type: ancestor.type,
                                                 kind: .show, title: showTitle, posterURL: ancestor.parentPosterURL)
                        index[showID] = DownloadIndexEntry(item: showItem, filename: nil)
                    }
                }
            }

            if ancestors.isEmpty, item.parentKind == .season,
               let seasonID = item.parentID, !seasonID.isEmpty {
                if index[seasonID] == nil {
                    var seasonItem = MediaItem(id: seasonID, source: item.source, type: item.type,
                                               kind: .season, title: item.parentTitle ?? "Season",
                                               posterURL: item.parentPosterURL)
                    if let showID = item.attributes["grandparentRatingKey"], !showID.isEmpty,
                       let showTitle = item.attributes["grandparentTitle"], !showTitle.isEmpty {
                        seasonItem.parentID = showID
                        seasonItem.parentKind = .show
                        if index[showID] == nil {
                            let showPosterURL = item.attributes["grandparentPosterURL"].flatMap { URL(string: $0) }
                            let showItem = MediaItem(id: showID, source: item.source, type: item.type,
                                                     kind: .show, title: showTitle, posterURL: showPosterURL)
                            index[showID] = DownloadIndexEntry(item: showItem, filename: nil)
                        }
                    }
                    index[seasonID] = DownloadIndexEntry(item: seasonItem, filename: nil)
                }
            }

            Self.writeIndex(index, to: folder)

            switch item.type {
            case .movies: downloadedMovieIDs.insert(item.id)
            case .tvShows: downloadedTVShowIDs.insert(item.id)
            case .music: downloadedMusicIDs.insert(item.id)
            }

            var currentFileURL = destination
            if item.type != .music {
                let task = Task<URL?, Never> {
                    await self.maybeTranscode(item: item, fileURL: destination, folder: folder)
                }
                activeTasks[item.id] = task
                if let transcodedURL = await task.value {
                    currentFileURL = transcodedURL
                    let newRelative = String(transcodedURL.path.dropFirst(folder.path.count + 1))
                    var updatedIndex = Self.readIndexFromFolder(folder)
                    updatedIndex[item.id] = DownloadIndexEntry(item: item, filename: newRelative)
                    Self.writeIndex(updatedIndex, to: folder)
                }
                activeTasks.removeValue(forKey: item.id)
            }

            await downloadArtwork(for: item, fileURL: currentFileURL, destinationFolder: currentFileURL.deletingLastPathComponent())

            if item.kind == .episode {
                let episodeFolder = currentFileURL.deletingLastPathComponent()
                let hasSeason = ancestors.contains(where: { $0.kind == .season }) || item.parentKind == .season

                if hasSeason {
                    let showFolder = episodeFolder.deletingLastPathComponent()
                    let seasonFolderName = episodeFolder.lastPathComponent

                    if let seasonAncestor = ancestors.first(where: { $0.kind == .season }),
                       let url = seasonAncestor.posterURL {
                        await downloadArtwork(from: url, stem: seasonFolderName, destinationFolder: showFolder)
                    } else if item.parentKind == .season, let url = item.parentPosterURL {
                        await downloadArtwork(from: url, stem: seasonFolderName, destinationFolder: showFolder)
                    }

                    let rootFolder = showFolder.deletingLastPathComponent()
                    let showFolderName = showFolder.lastPathComponent

                    if let showAncestor = ancestors.first(where: { $0.kind == .show }),
                       let url = showAncestor.posterURL {
                        await downloadArtwork(from: url, stem: showFolderName, destinationFolder: rootFolder)
                    } else if let seasonAncestor = ancestors.first(where: { $0.kind == .season }),
                              let url = seasonAncestor.parentPosterURL {
                        await downloadArtwork(from: url, stem: showFolderName, destinationFolder: rootFolder)
                    } else if let urlString = item.attributes["grandparentPosterURL"], let url = URL(string: urlString) {
                        await downloadArtwork(from: url, stem: showFolderName, destinationFolder: rootFolder)
                    } else {
                        let showFolder = episodeFolder
                        let rootFolder = showFolder.deletingLastPathComponent()
                        let showFolderName = showFolder.lastPathComponent
                        
                        if let showAncestor = ancestors.first(where: { $0.kind == .show }),
                           let url = showAncestor.posterURL {
                            await downloadArtwork(from: url, stem: showFolderName, destinationFolder: rootFolder)
                        } else if item.parentKind == .show, let url = item.parentPosterURL {
                            await downloadArtwork(from: url, stem: showFolderName, destinationFolder: rootFolder)
                        }
                    }
                }
            }

            return true
        } catch {
            if showAlerts {
                Self.alert(title: "Download Failed", message: error.localizedDescription)
            }
            return false
        }
    }
    
    private func downloadFileWithProgress(url: URL, itemID: String) async throws -> (URL, URLResponse) {
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let tempURL = tempURL, let response = response else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                let stableTemp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                do {
                    try? FileManager.default.removeItem(at: stableTemp)
                    try FileManager.default.moveItem(at: tempURL, to: stableTemp)
                    continuation.resume(returning: (stableTemp, response))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            
            let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                let fraction = progress.fractionCompleted
                DispatchQueue.main.async {
                    self?.downloadProgress[itemID] = fraction
                }
            }
            
            objc_setAssociatedObject(task, "progressObservation", observation, .OBJC_ASSOCIATION_RETAIN)
            
            task.resume()
        }
    }

    private func downloadArtwork(for item: MediaItem, fileURL: URL?, destinationFolder: URL, name: String? = nil) async {
        guard let posterURL = item.posterURL else { return }
        await downloadArtwork(from: posterURL, stem: name ?? {
            if (item.kind == .episode || item.kind == .movie), let fileURL {
                return fileURL.deletingPathExtension().lastPathComponent
            }
            return "poster"
        }(), destinationFolder: destinationFolder)
    }

    private func downloadArtwork(from posterURL: URL, stem: String, destinationFolder: URL) async {
        let preferredExt = posterURL.pathExtension.lowercased() == "png" ? "png" : "jpg"
        do {
            let (tempURL, response) = try await URLSession.shared.download(from: posterURL)
            var finalExt = preferredExt
            if let mime = response.mimeType {
                if mime.contains("png") { finalExt = "png" }
                else if mime.contains("jpeg") || mime.contains("jpg") { finalExt = "jpg" }
            }
            let finalDest = destinationFolder.appending(path: "\(stem).\(finalExt)")
            if FileManager.default.fileExists(atPath: finalDest.path) { return }
            try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: finalDest)
            try FileManager.default.moveItem(at: tempURL, to: finalDest)
        } catch {
            print("Failed to download artwork: \(error)")
        }
    }

    private nonisolated static func sanitizePathComponent(_ s: String) -> String {
        var result = s.replacing("/", with: "-").replacing(":", with: "-")
        while result.hasPrefix(".") { result = String(result.dropFirst()) }
        return result.isEmpty ? "Unknown" : result
    }

    private static func relativePath(for item: MediaItem, ancestors: [MediaItem], fileExtension ext: String) -> String {
        if item.kind == .episode {
            let originalComponents = (item.attributes["originalPath"] ?? "")
                .components(separatedBy: CharacterSet(charactersIn: "\\/")).filter { !$0.isEmpty }
            let filename = originalComponents.last ?? "\(item.id)-\(sanitizePathComponent(item.title)).\(ext)"

            let showName: String?
            if let s = ancestors.first(where: { $0.kind == .show }) {
                showName = s.title
            } else if item.parentKind == .show, let pt = item.parentTitle, !pt.isEmpty {
                showName = pt
            } else if let gt = item.attributes["grandparentTitle"], !gt.isEmpty {
                showName = gt
            } else {
                showName = nil
            }

            let seasonName: String?
            if let s = ancestors.first(where: { $0.kind == .season }) {
                seasonName = s.title
            } else if item.parentKind == .season, let pt = item.parentTitle, !pt.isEmpty {
                seasonName = pt
            } else if let idxStr = item.attributes["parentIndex"], let idx = Int(idxStr) {
                seasonName = "Season \(String(format: "%02d", idx))"
            } else {
                let regex = try? NSRegularExpression(pattern: #"[Ss](\d{1,2})[Ee]\d{1,2}"#)
                let range = NSRange(filename.startIndex..., in: filename)
                if let match = regex?.firstMatch(in: filename, range: range),
                   let numRange = Range(match.range(at: 1), in: filename),
                   let num = Int(filename[numRange]) {
                    seasonName = "Season \(String(format: "%02d", num))"
                } else {
                    seasonName = nil
                }
            }

            if let show = showName.map(sanitizePathComponent), let season = seasonName.map(sanitizePathComponent) {
                return "\(show)/\(season)/\(filename)"
            } else if let show = showName.map(sanitizePathComponent) {
                return "\(show)/\(filename)"
            } else if let season = seasonName.map(sanitizePathComponent) {
                return "\(season)/\(filename)"
            }
            return filename
        }

        if let original = item.attributes["originalPath"], !original.isEmpty {
            let components = original.components(separatedBy: CharacterSet(charactersIn: "\\/")).filter { !$0.isEmpty }
            if !components.isEmpty {
                switch item.type {
                case .tvShows: return components.suffix(3).joined(separator: "/")
                case .music:   return components.suffix(3).joined(separator: "/")
                case .movies:  return components.suffix(2).joined(separator: "/")
                }
            }
        }

        let filename = "\(item.id)-\(sanitizePathComponent(item.title)).\(ext)"
        switch item.kind {
        case .track:
            let artistName = item.subtitle ?? ancestors.first(where: { $0.kind == .artist })?.title
            let albumName = item.parentTitle ?? ancestors.first(where: { $0.kind == .album })?.title
            if let artist = artistName.map(sanitizePathComponent),
               let album = albumName.map(sanitizePathComponent) {
                return "\(artist)/\(album)/\(filename)"
            } else if let album = albumName.map(sanitizePathComponent) {
                return "\(album)/\(filename)"
            }
            return filename
        default:
            return filename
        }
    }

    private static func expectedSize(of url: URL) async -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return 0 }
        let length = response.expectedContentLength
        return length > 0 ? length : 0
    }

    private static func alert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApplication.shared.activate()
        alert.runModal()
    }

    // MARK: - Post-download transcoding

    private func maybeTranscode(item: MediaItem, fileURL: URL, folder: URL) async -> URL? {
        let modeRaw = UserDefaults.standard.string(forKey: "transcodeMode") ?? "Automatic"
        if modeRaw == "Disabled" { return nil }

        let thresholdRaw = UserDefaults.standard.string(forKey: SettingsKeys.transcodeThreshold(item.type)) ?? ""
        let presetRaw = UserDefaults.standard.string(forKey: SettingsKeys.transcodePreset(item.type)) ?? ""

        guard let threshold = TranscodeThreshold(rawValue: thresholdRaw),
              threshold != .disabled,
              let thresholdBytes = threshold.bytes else { return nil }

        guard let fileSize = try? fileURL.resourceValues(forKeys: [.totalFileSizeKey]).totalFileSize,
              Int64(fileSize) >= thresholdBytes else { return nil }

        var finalPreset: TranscodePreset? = TranscodePreset(rawValue: presetRaw)

        if modeRaw == "Prompted" {
            let userSelectedPreset = await withCheckedContinuation { continuation in
                let request = TranscodePromptRequest(item: item, preset: finalPreset, continuation: continuation)
                DispatchQueue.main.async {
                    self.pendingPrompts[item.id] = request
                }
            }
            guard let selected = userSelectedPreset else { return nil }
            finalPreset = selected
        }

        guard let preset = finalPreset else { return nil }

        // Wait for a hardware encoder slot. Returns early if cancelled while queued.
        do {
            try await transcodePool.waitForSlot()
        } catch {
            return nil
        }

        // Show in the Converting UI now that encoding is about to begin.
        transcodeQueue.append(TranscodeQueueEntry(id: item.id, title: item.title, posterURL: item.posterURL, mediaType: item.type, progress: 0))

        let pool = transcodePool
        let itemID = item.id
        defer {
            Task { await pool.release() }
            Task { @MainActor [weak self] in self?.transcodeQueue.removeAll { $0.id == itemID } }
        }

        do {
            return try await VideoTranscoder.transcode(fileURL: fileURL, preset: preset) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let idx = self.transcodeQueue.firstIndex(where: { $0.id == itemID }) {
                        self.transcodeQueue[idx].progress = progress
                    }
                }
            }
        } catch {
            print("[Transcode] Failed for \(item.title): \(error.localizedDescription)")
            return nil
        }
    }

    /// Triggers a manual transcode, bypassing the automatic threshold check.
    private func forceTranscode(item: MediaItem, preset: TranscodePreset) async {
        guard let folder = Self.resolvedFolder(for: item.type) else { return }
        guard let fileURL = localURL(for: item) else { return }

        // Respect the hardware engine pool so manual transcodes don't pile on top of automatic ones.
        do {
            try await transcodePool.waitForSlot()
        } catch {
            return
        }

        DispatchQueue.main.async {
            self.transcodeQueue.append(TranscodeQueueEntry(id: item.id, title: item.title, posterURL: item.posterURL, mediaType: item.type, progress: 0))
        }

        let pool = transcodePool
        let itemID = item.id
        defer {
            Task { await pool.release() }
            DispatchQueue.main.async { self.transcodeQueue.removeAll { $0.id == itemID } }
        }

        do {
            let transcodedURL = try await VideoTranscoder.transcode(fileURL: fileURL, preset: preset) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let idx = self.transcodeQueue.firstIndex(where: { $0.id == itemID }) {
                        self.transcodeQueue[idx].progress = progress
                    }
                }
            }
            let newRelative = String(transcodedURL.path.dropFirst(folder.path.count + 1))
            var updatedIndex = Self.readIndexFromFolder(folder)
            updatedIndex[item.id] = DownloadIndexEntry(item: item, filename: newRelative)
            Self.writeIndex(updatedIndex, to: folder)
        } catch {
            print("[Transcode] Manual transcode failed: \(error.localizedDescription)")
        }
    }

    func applyStorageOptimisationSettings() {
        guard !activeTasks.isEmpty else { return }

        // Snapshot queued items so we can restart them with the new settings.
        let entriesToRestart = transcodeQueue

        // Cancel every active transcode; the pool slots free up as they unwind.
        for task in activeTasks.values { task.cancel() }
        activeTasks.removeAll()

        // Restart each item. Pool limits encoding concurrency while the cancelled
        // transcodes drain their remaining pool slots.
        for entry in entriesToRestart {
            guard let folder = Self.resolvedFolder(for: entry.mediaType) else { continue }
            let index = Self.readIndexFromFolder(folder)
            guard let indexEntry = index[entry.id],
                  let filename = indexEntry.filename else { continue }
            let fileURL = folder.appending(path: filename)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

            let task = Task<URL?, Never> { [weak self] in
                await self?.maybeTranscode(item: indexEntry.item, fileURL: fileURL, folder: folder)
            }
            activeTasks[entry.id] = task

            let capturedID = entry.id
            Task { [weak self] in
                if let url = await task.value {
                    let newRelative = String(url.path.dropFirst(folder.path.count + 1))
                    var updatedIndex = Self.readIndexFromFolder(folder)
                    updatedIndex[capturedID] = DownloadIndexEntry(item: indexEntry.item, filename: newRelative)
                    Self.writeIndex(updatedIndex, to: folder)
                }
                self?.activeTasks.removeValue(forKey: capturedID)
            }
        }
    }
}
#endif // os(macOS)
