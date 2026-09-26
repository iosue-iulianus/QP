import Foundation
import ImageIO
import SwiftUI

/// URL sessions for poster loading. The persistent one keeps artwork in a
/// dedicated disk cache so posters don't re-download every launch; the
/// ephemeral one (used when "Cache Artwork Locally" is off) keeps nothing
/// on disk.
nonisolated enum ArtworkCache {
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

    /// The session matching the "Cache Artwork Locally" preference (default on).
    static var session: URLSession {
        UserDefaults.standard.object(forKey: SettingsKeys.cacheArtwork) as? Bool ?? true
            ? persistentSession : ephemeralSession
    }

    static var diskUsageBytes: Int {
        persistentSession.configuration.urlCache?.currentDiskUsage ?? 0
    }

    static func clear() {
        persistentSession.configuration.urlCache?.removeAllCachedResponses()
        ephemeralSession.configuration.urlCache?.removeAllCachedResponses()
    }

    /// Fetches and decodes artwork off the main thread, downsampled so a
    /// full-size poster doesn't sit in memory at original resolution.
    @concurrent
    static func image(at url: URL) async -> CGImage? {
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        guard let (data, _) = try? await session.data(for: request),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // ponytail: fixed 600 px cap covers the largest view (280 pt music artwork @2x).
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Replacement for `AsyncImage(request:)` + `.asyncImageURLSession(_:)`,
/// which only exist on macOS 27. Loads through `ArtworkCache` on macOS 26+.
struct ArtworkImage<Placeholder: View>: View {
    let url: URL
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            image = nil
            image = await ArtworkCache.image(at: url)
        }
    }
}
