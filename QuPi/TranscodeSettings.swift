#if os(macOS)
import AVFoundation

/// File-size threshold above which a downloaded video is automatically transcoded.
enum TranscodeThreshold: String, CaseIterable, Codable, Identifiable {
    case disabled
    case gb1 = "1"
    case gb3 = "3"
    case gb5 = "5"
    case gb15 = "15"
    case gb25 = "25"
    case gb50 = "50"

    var id: String { rawValue }

    var bytes: Int64? {
        guard self != .disabled, let value = Int64(rawValue) else { return nil }
        return value * 1_000_000_000
    }

    /// Text shown in the picker for this option. `.disabled` uses a descriptive prompt.
    var label: String {
        switch self {
        case .disabled: "Size Threshold"
        case .gb1: "1 GB"
        case .gb3: "3 GB"
        case .gb5: "5 GB"
        case .gb15: "15 GB"
        case .gb25: "25 GB"
        case .gb50: "50 GB"
        }
    }

    static var movieOptions: [TranscodeThreshold] { [.disabled, .gb5, .gb15, .gb25, .gb50] }
    static var tvOptions: [TranscodeThreshold] { [.disabled, .gb1, .gb3, .gb5] }
}

/// Vertical resolution tier for transcoding output.
enum TranscodeResolution: Int, Comparable, CaseIterable, Codable {
    case p720 = 720
    case p1080 = 1080
    case p2160 = 2160

    static func < (lhs: TranscodeResolution, rhs: TranscodeResolution) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Derives the tier from the longer edge of a video track's natural size,
    /// matching the convention used by Plex / Jellyfin for wide-aspect content.
    static func from(naturalSize: CGSize) -> TranscodeResolution {
        let longEdge = max(naturalSize.width, naturalSize.height)
        if longEdge >= 3800 { return .p2160 }
        if longEdge >= 1900 { return .p1080 }
        return .p720
    }

    var label: String {
        switch self {
        case .p720: "720p"
        case .p1080: "1080p"
        case .p2160: "4K"
        }
    }

    /// Maximum output dimensions for this resolution tier.
    /// Used by the FFmpeg scale filter to constrain output size without upscaling.
    var maxDimensions: (width: Int, height: Int) {
        switch self {
        case .p720:  (1280, 720)
        case .p1080: (1920, 1080)
        case .p2160: (3840, 2160)
        }
    }
}

/// Compression quality tier for transcoding output.
enum TranscodeQuality: String, CaseIterable, Codable, Identifiable {
    case low, medium, high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    func videoBitrate(for resolution: TranscodeResolution) -> Int {
        switch (resolution, self) {
        case (.p720,  .low):    return  2_000_000
        case (.p720,  .medium): return  3_000_000
        case (.p720,  .high):   return  5_000_000
        case (.p1080, .low):    return  4_000_000
        case (.p1080, .medium): return  6_000_000
        case (.p1080, .high):   return 10_000_000
        case (.p2160, .low):    return 10_000_000
        case (.p2160, .medium): return 18_000_000
        case (.p2160, .high):   return 30_000_000
        }
    }

    var audioBitrate: Int {
        switch self {
        case .low:    return 128_000
        case .medium: return 192_000
        case .high:   return 256_000
        }
    }
}

/// A combined HEVC transcoding preset: resolution tier + quality.
struct TranscodePreset: Hashable, Codable, Identifiable {
    let resolution: TranscodeResolution
    let quality: TranscodeQuality

    var id: String { rawValue }

    /// Stable storage key, e.g. "1080_high".
    var rawValue: String { "\(resolution.rawValue)_\(quality.rawValue)" }

    var displayName: String { "\(resolution.label) HEVC \(quality.label)" }

    init(resolution: TranscodeResolution, quality: TranscodeQuality) {
        self.resolution = resolution
        self.quality = quality
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: "_")
        guard parts.count == 2,
              let resInt = Int(parts[0]),
              let res = TranscodeResolution(rawValue: resInt),
              let q = TranscodeQuality(rawValue: String(parts[1])) else { return nil }
        self.resolution = res
        self.quality = q
    }

    /// All nine combinations ordered from smallest to largest.
    static let allCases: [TranscodePreset] = TranscodeResolution.allCases.flatMap { res in
        TranscodeQuality.allCases.map { TranscodePreset(resolution: res, quality: $0) }
    }

    /// Returns a copy capped so the resolution never exceeds the source tier.
    func capped(to sourceResolution: TranscodeResolution) -> TranscodePreset {
        TranscodePreset(resolution: min(resolution, sourceResolution), quality: quality)
    }

    /// AVFoundation video output settings. Dimensions are rounded to even values (codec requirement).
    func videoOutputConfiguration(scaledFrom naturalSize: CGSize) -> [String: Any] {
        let targetH = min(CGFloat(resolution.rawValue), naturalSize.height)
        let aspectRatio = naturalSize.width / naturalSize.height
        // Round to nearest even number — required by most codecs.
        let h = (targetH / 2).rounded() * 2
        let w = ((h * aspectRatio) / 2).rounded() * 2
        return [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(w),
            AVVideoHeightKey: Int(h),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: quality.videoBitrate(for: resolution),
                AVVideoProfileLevelKey: "HEVC_Main_AutoLevel",
            ] as [String: Any],
        ]
    }

    func audioOutputConfiguration() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVEncoderBitRateKey: quality.audioBitrate,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
        ]
    }
}

/// One entry in the active transcoding queue, observed by the Converting section.
struct TranscodeQueueEntry: Identifiable {
    let id: String
    let title: String
    let posterURL: URL?
    let mediaType: MediaType
    var progress: Float  // 0.0–1.0
}

/// What happens to the transcode queue when the app is quit.
enum QueueOnCloseBehavior: String, CaseIterable, Identifiable {
    case abandonQueue
    case keepQueue

    var id: String { rawValue }

    var label: String {
        switch self {
        case .abandonQueue: "Abandon Queue"
        case .keepQueue: "Keep Queue"
        }
    }
}

/// Lightweight record persisted to UserDefaults when the user quits with Keep Queue active.
/// On next launch, DownloadManager looks up each item in the download index and re-transcodes it.
struct SavedPendingTranscode: Codable {
    let itemID: String
    let mediaType: MediaType
}
#endif
