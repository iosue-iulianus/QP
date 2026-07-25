#if os(macOS)
import SwiftUI

// MARK: - Downloading

/// Horizontal strip of poster thumbnails for items currently being downloaded.
struct DownloadingActivitySection: View {
    let items: [MediaItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Downloading", systemImage: "arrow.down.circle")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.top, 8)
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(items, id: \.uniqueID) { item in
                        ActivityCarouselCell(title: item.title, posterURL: item.posterURL, progress: nil)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
        }
    }
}

// MARK: - Converting

/// Horizontal strip of poster thumbnails for items currently being transcoded.
struct ConvertingActivitySection: View {
    let queue: [TranscodeQueueEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Converting", systemImage: "gearshape.2")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if queue.count > 1 {
                    Text("\(queue.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(queue) { entry in
                        ActivityCarouselCell(
                            title: entry.title,
                            posterURL: entry.posterURL,
                            progress: entry.progress
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
        }
    }
}

// MARK: - Cell

/// Compact poster thumbnail used by DownloadingActivitySection and ConvertingActivitySection.
struct ActivityCarouselCell: View {
    let title: String
    let posterURL: URL?
    /// Nil → indeterminate spinner (Downloading). 0–1 → progress bar (Converting).
    let progress: Float?

    static let width: CGFloat = 60
    static let height: CGFloat = 90

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottom) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    if let url = posterURL {
                        AsyncImage(request: URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)) { phase in
                            if let image = phase.image {
                                image.resizable().aspectRatio(contentMode: .fill)
                            }
                        }
                    }
                }
                if let progress {
                    Color.accentColor
                        .frame(height: 4)
                        .scaleEffect(x: CGFloat(progress), y: 1, anchor: .leading)
                        .animation(.linear(duration: 0.3), value: progress)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                        .padding(6)
                }
            }
            .frame(width: Self.width, height: Self.height)
            .clipShape(.rect(cornerRadius: 6))

            Text(title)
                .font(.caption2)
                .lineLimit(1)
                .frame(width: Self.width, alignment: .leading)
        }
    }
}
#endif
