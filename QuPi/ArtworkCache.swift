import Foundation

/// URL sessions for poster loading. The persistent one keeps artwork in a
/// dedicated disk cache so posters don't re-download every launch; the
/// ephemeral one (used when "Cache Artwork Locally" is off) keeps nothing
/// on disk.
enum ArtworkCache {
    static let persistentSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        let directory = URL.cachesDirectory.appending(path: "Artwork")
        configuration.urlCache = URLCache(
            memoryCapacity: 64 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024,
            directory: directory
        )
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration)
    }()

    static let ephemeralSession = URLSession(configuration: .ephemeral)

    static var diskUsageBytes: Int {
        persistentSession.configuration.urlCache?.currentDiskUsage ?? 0
    }

    static func clear() {
        persistentSession.configuration.urlCache?.removeAllCachedResponses()
        ephemeralSession.configuration.urlCache?.removeAllCachedResponses()
    }
}
