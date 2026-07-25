#if os(macOS)
@preconcurrency import AVFoundation
import Foundation
import VideoToolbox

/// Transcodes a local video file to HEVC using Apple Silicon's hardware encoder.
///
/// Primary path: AVAssetReader + AVAssetWriter (no third-party dependency).
/// Fallback: system FFmpeg (searched at common Homebrew paths) when the AVFoundation
/// pipeline fails — typically because the source contains an unsupported audio codec
/// (DTS, TrueHD, AC3) or an unusual video codec inside an MKV container.
struct VideoTranscoder {
    enum TranscoderError: LocalizedError {
        case noVideoTrack
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "The file has no video track."
            case .exportFailed(let reason): return "Transcode failed: \(reason)"
            }
        }
    }

    // MARK: - Public entry point

    /// Re-encodes the video at `fileURL` using `preset`, replacing the original on disk.
    ///
    /// Tries AVFoundation first. On failure (except `noVideoTrack`), falls back to FFmpeg
    /// if it can be found at a Homebrew path. If neither succeeds the error is rethrown and
    /// the original file is left intact.
    static func transcode(
        fileURL: URL,
        preset: TranscodePreset,
        progress: (@Sendable (Float) -> Void)? = nil
    ) async throws -> URL {
        do {
            return try await transcodeWithAVFoundation(fileURL: fileURL, preset: preset, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch TranscoderError.noVideoTrack {
            throw TranscoderError.noVideoTrack  // FFmpeg cannot help without a video track
        } catch {
            guard let ffmpeg = ffmpegPath() else {
                print("[Transcode] AVFoundation failed (\(error.localizedDescription)); FFmpeg not found — install via: brew install ffmpeg")
                throw error
            }
            print("[Transcode] AVFoundation failed (\(error.localizedDescription)); retrying with FFmpeg at \(ffmpeg.path(percentEncoded: false)).")
            return try await transcodeWithFFmpeg(
                fileURL: fileURL, preset: preset, ffmpegURL: ffmpeg, progress: progress
            )
        }
    }

    // MARK: - Hardware capabilities

    /// Returns the number of simultaneous hardware HEVC encode sessions supported on this device.
    ///
    /// Uses `VTCopyVideoEncoderList` to read `kVTVideoEncoderList_InstanceLimit` from the hardware
    /// HEVC encoder entry — the value maps directly to the number of dedicated media encode engines.
    /// Falls back to inferring tier from performance core count when the VideoToolbox key is absent.
    static func hardwareEncodeEngineCount() -> Int {
        var encoderList: CFArray?
        if VTCopyVideoEncoderList(nil, &encoderList) == noErr, let array = encoderList as? NSArray {
            var maxInstances = 0
            for element in array {
                guard let dict = element as? NSDictionary else { continue }
                guard (dict[kVTVideoEncoderList_IsHardwareAccelerated] as? Bool) == true else { continue }
                guard let codecNum = dict[kVTVideoEncoderList_CodecType] as? NSNumber,
                      CMVideoCodecType(codecNum.uint32Value) == kCMVideoCodecType_HEVC else { continue }
                if let limit = (dict[kVTVideoEncoderList_InstanceLimit] as? NSNumber)?.intValue {
                    maxInstances = max(maxInstances, limit)
                }
            }
            if maxInstances > 0 { return maxInstances }
        }
        // Fallback: infer from P-core count (proxy for chip tier on Apple Silicon).
        // Ultra (≥20 P-cores) → 4 engines, Pro/Max (≥6) → 2 engines, base → 1 engine.
        var perfCores: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        sysctlbyname("hw.perflevel0.physicalcpu", &perfCores, &size, nil, 0)
        if perfCores >= 20 { return 4 }
        if perfCores >= 6  { return 2 }
        return 1
    }

    // MARK: - AVFoundation path

        private static func transcodeWithAVFoundation(
            fileURL: URL,
            preset: TranscodePreset,
            progress: (@Sendable (Float) -> Void)?
        ) async throws -> URL {
            let asset = AVURLAsset(url: fileURL)

            // Load all track properties asynchronously
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                throw TranscoderError.noVideoTrack
            }
            let naturalSize = try await videoTrack.load(.naturalSize)
            let preferredTransform = try await videoTrack.load(.preferredTransform)
            let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
            let duration = try await asset.load(.duration)

            let sourceResolution = TranscodeResolution.from(naturalSize: naturalSize)
            let effectivePreset = preset.capped(to: sourceResolution)
            let videoConfig = effectivePreset.videoOutputConfiguration(scaledFrom: naturalSize)

            // Build output paths.
            let outputFilename = updatedFilename(
                original: fileURL.lastPathComponent,
                resolution: effectivePreset.resolution
            )
            let outputDir = fileURL.deletingLastPathComponent()
            let tempURL = outputDir.appending(path: outputFilename + ".transcoding.tmp")
            let finalURL = outputDir.appending(path: outputFilename)
            try? FileManager.default.removeItem(at: tempURL)

            guard let outW = videoConfig[AVVideoWidthKey] as? Int,
                  let outH = videoConfig[AVVideoHeightKey] as? Int else {
                throw TranscoderError.exportFailed("Video configuration is missing width or height")
            }

            let fps = max(nominalFrameRate, 1)
            let scaleTransform = scalingTransform(
                from: naturalSize,
                preferredTransform: preferredTransform,
                to: CGSize(width: outW, height: outH)
            )

            var layerConfig = AVVideoCompositionLayerInstruction.Configuration(assetTrack: videoTrack)
            layerConfig.setTransform(scaleTransform, at: .zero)
            let layerInstruction = AVVideoCompositionLayerInstruction(configuration: layerConfig)

            let instructionConfig = AVVideoCompositionInstruction.Configuration(
                backgroundColor: nil,
                enablePostProcessing: false,
                layerInstructions: [layerInstruction],
                requiredSourceSampleDataTrackIDs: [],
                timeRange: CMTimeRange(start: .zero, duration: duration)
            )
            let instruction = AVVideoCompositionInstruction(configuration: instructionConfig)

            let compositionConfig = AVVideoComposition.Configuration(
                frameDuration: CMTime(value: 1, timescale: CMTimeScale(fps.rounded())),
                instructions: [instruction],
                renderSize: CGSize(width: outW, height: outH)
            )
            let videoComposition = AVVideoComposition(configuration: compositionConfig)

            // Reader Setup
            let reader = try AVAssetReader(asset: asset)

            let videoOutput = AVAssetReaderVideoCompositionOutput(
                videoTracks: videoTracks,
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            )
            videoOutput.videoComposition = videoComposition
            let videoProvider = reader.outputProvider(for: videoOutput)

            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            var audioProvider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>? = nil
            if !audioTracks.isEmpty {
                let pcmSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsNonInterleaved: false,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ]
                let ao = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcmSettings)
                audioProvider = reader.outputProvider(for: ao)
            }

            // Writer Setup
            let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = true

            guard writer.canApply(outputSettings: videoConfig, forMediaType: .video) else {
                throw TranscoderError.exportFailed("Writer does not support the video configuration")
            }
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoConfig)
            let videoReceiver = writer.inputReceiver(for: videoInput)

            var audioReceiver: AVAssetWriterInput.SampleBufferReceiver? = nil
            if audioProvider != nil {
                let ai = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: effectivePreset.audioOutputConfiguration()
                )
                audioReceiver = writer.inputReceiver(for: ai)
            }

            // Start reading and writing
            try reader.start()
            try writer.start()
            writer.startSession(atSourceTime: .zero)

            let durationSeconds = duration.seconds
            
            // Make sure your implementation of `progress` dispatches to the MainActor if it updates the UI!
            progress?(0)

            do {
                try await withTaskCancellationHandler {
                    try await encodeLoop(
                        videoProvider: videoProvider,
                        videoReceiver: videoReceiver,
                        audioProvider: audioProvider,
                        audioReceiver: audioReceiver,
                        reader: reader,
                        writer: writer,
                        durationSeconds: durationSeconds,
                        progress: progress
                    )
                } onCancel: {
                    writer.cancelWriting()
                    reader.cancelReading()
                }
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                throw error
            }

            try? FileManager.default.removeItem(at: finalURL)
            try FileManager.default.moveItem(at: tempURL, to: finalURL)
            if fileURL.standardizedFileURL != finalURL.standardizedFileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
            return finalURL
        }

    // MARK: - FFmpeg path

    private static func transcodeWithFFmpeg(
        fileURL: URL,
        preset: TranscodePreset,
        ffmpegURL: URL,
        progress: (@Sendable (Float) -> Void)?
    ) async throws -> URL {
        // Load source resolution from metadata (works even when codec decoding fails).
        let asset = AVURLAsset(url: fileURL)
        let sourceResolution: TranscodeResolution
        if let tracks = try? await asset.loadTracks(withMediaType: .video),
           let track = tracks.first,
           let size = try? await track.load(.naturalSize) {
            sourceResolution = TranscodeResolution.from(naturalSize: size)
        } else {
            sourceResolution = .p2160  // assume worst case; min() in filter prevents upscaling
        }

        let effectivePreset = preset.capped(to: sourceResolution)
        let dims = effectivePreset.resolution.maxDimensions

        // Load duration for progress calculation.
        let totalDuration: Double
        if let d = try? await asset.load(.duration) {
            totalDuration = d.seconds
        } else {
            totalDuration = 0
        }

        // Build output paths (same naming convention as AVFoundation path).
        let outputFilename = updatedFilename(
            original: fileURL.lastPathComponent,
            resolution: effectivePreset.resolution
        )
        let outputDir = fileURL.deletingLastPathComponent()
        let tempURL = outputDir.appending(path: outputFilename + ".transcoding.tmp")
        let finalURL = outputDir.appending(path: outputFilename)
        try? FileManager.default.removeItem(at: tempURL)

        // Scale to fit within the target tier. We use a math function to ensure the final output
        // is divisible by 2, as Apple's HEVC Hardware encoder rejects odd-numbered pixel dimensions.
        let vf = "scale='trunc(min(iw,\(dims.width))/2)*2':'trunc(min(ih,\(dims.height))/2)*2'"
        let videoBitrate = effectivePreset.quality.videoBitrate(for: effectivePreset.resolution)
        let audioBitrate = effectivePreset.quality.audioBitrate

        let args: [String] = [
            "-i", fileURL.path(percentEncoded: false),
            "-map", "0:v:0?",   // Explicitly take only the first video track (if it exists)
            "-map", "0:a:0?",   // Explicitly take only the first audio track
            "-sn",              // Explicitly strip subtitles (MP4 doesn't support MKV's PGS/ASS natively)
            "-dn",              // Explicitly strip data/attachments (Fonts inside MKVs cause FFmpeg to panic)
            "-c:v", "hevc_videotoolbox",
            "-b:v", "\(videoBitrate)",
            "-vf", vf,
            "-c:a", "aac",
            "-b:a", "\(audioBitrate)",
            "-ar", "48000", "-ac", "2",
            // +faststart requires a seek-and-rewrite pass at the end; hevc_videotoolbox output
            // doesn't support this cleanly and causes FFmpeg to hang, leaving a file without
            // a moov atom. Omit it — for local playback the moov position is irrelevant.
            "-progress", "pipe:1",
            "-nostats",
            "-f", "mp4",        // Explicitly set format to MP4 (solves the ".tmp" Invalid argument error)
            "-y", tempURL.path(percentEncoded: false),
        ]

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = args
        // Provide a PATH that includes the Homebrew prefix so FFmpeg can locate shared
        // libraries and helper binaries even when the app was launched outside a shell.
        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin"
        env["PATH"] = extraPaths + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe  // Captures actual error logs

        try process.run()
        // Close the parent's copies of the write ends so the read loops get EOF when FFmpeg exits.
        // Without this, the parent holds the pipe open even after FFmpeg exits and the async
        // readers never terminate, causing the transcode to hang indefinitely.
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        progress?(0)

        // Safely shares the detected source duration between the two concurrent pipe readers.
        // We use an actor because the stderr reader (which finds the Duration line) and the
        // stdout progress reader both run in separate unstructured Tasks.
        actor DurationHolder {
            var seconds: Double
            init(_ initial: Double) { seconds = initial }
            func set(_ d: Double) { if d > 0, seconds == 0 { seconds = d } }
        }
        let durationHolder = DurationHolder(totalDuration)

        // Parses "  Duration: HH:MM:SS.ss, ..." from FFmpeg's stderr preamble.
        let parseDuration: @Sendable (String) -> Double? = { line in
            guard let range = line.range(of: "Duration: ") else { return nil }
            let timeString = line[range.upperBound...].prefix(while: { $0 != "," })
            let parts = timeString.split(separator: ":")
            guard parts.count == 3,
                  let h = Double(parts[0]),
                  let m = Double(parts[1]),
                  let s = Double(parts[2]) else { return nil }
            return h * 3600 + m * 60 + s
        }

        // Read progress from FFmpeg's `-progress pipe:1` output concurrently.
        let progressTask = Task {
            for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                if line.hasPrefix("out_time_us="),
                   let us = Int64(line.dropFirst(12)) {
                    let elapsed = Double(us) / 1_000_000
                    let dur = await durationHolder.seconds
                    if dur > 0 {
                        progress?(Float(min(elapsed / dur, 1)))
                    }
                }
            }
        }

        // Read stderr concurrently to capture the failure reason and extract source
        // duration when AVFoundation couldn't open the file (e.g. unsupported MKV codec).
        let stderrTask = Task {
            var lastError = "Unknown FFmpeg error"
            for try await line in stderrPipe.fileHandleForReading.bytes.lines {
                if !line.isEmpty { lastError = line }
                if line.contains("Duration:"), let d = parseDuration(line) {
                    await durationHolder.set(d)
                }
            }
            return lastError
        }

        // Await process exit without blocking the cooperative thread pool.
        let exitCode = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { p in
                    continuation.resume(returning: p.terminationStatus)
                }
            }
        } onCancel: {
            process.terminate()
        }

        progressTask.cancel()
        let errorReason = (try? await stderrTask.value) ?? "Unknown FFmpeg error"

        guard exitCode == 0 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw TranscoderError.exportFailed("FFmpeg exited with code \(exitCode). Reason: \(errorReason)")
        }

        print("[Transcode] FFmpeg finished successfully for \(fileURL.lastPathComponent)")

        // Atomically replace the original.
        try? FileManager.default.removeItem(at: finalURL)
        do {
            try FileManager.default.moveItem(at: tempURL, to: finalURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        if fileURL.standardizedFileURL != finalURL.standardizedFileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        return finalURL
    }

    // MARK: - FFmpeg discovery

    /// Returns the URL of an FFmpeg executable, or nil when not found.
    ///
    /// Checks well-known Homebrew and system paths first (no subprocess needed),
    /// then falls back to querying `which(1)` with an augmented PATH so non-standard
    /// installs (conda, asdf, MacPorts, nix, etc.) are also found.
    private static func ffmpegPath() -> URL? {
        let knownPaths = [
            "/opt/homebrew/bin/ffmpeg",  // Apple Silicon Homebrew
            "/usr/local/bin/ffmpeg",      // Intel Homebrew
            "/opt/local/bin/ffmpeg",      // MacPorts
            "/usr/bin/ffmpeg",
        ]
        if let found = knownPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return URL(filePath: found)
        }
        return ffmpegPathViaWhich()
    }

    /// Runs `/usr/bin/which ffmpeg` with a PATH that includes common Homebrew prefixes so
    /// the binary is found even when the app's inherited PATH is minimal (common in macOS apps
    /// launched outside a shell).
    private static func ffmpegPathViaWhich() -> URL? {
        let task = Process()
        task.executableURL = URL(filePath: "/usr/bin/which")
        task.arguments = ["ffmpeg"]
        task.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let found = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !found.isEmpty else { return nil }
        return URL(filePath: found)
    }

    // MARK: - AVFoundation encode loop

    /// Builds a CGAffineTransform that maps the video track (with its preferred orientation
    /// transform applied) into a target output frame, scaling to fit while preserving aspect ratio.
    private static func scalingTransform(
        from naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        to targetSize: CGSize
    ) -> CGAffineTransform {
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let displayW = abs(transformedRect.width)
        let displayH = abs(transformedRect.height)
        guard displayW > 0, displayH > 0 else { return preferredTransform }

        let scale = min(targetSize.width / displayW, targetSize.height / displayH)
        let scaledW = displayW * scale
        let scaledH = displayH * scale
        let tx = (targetSize.width - scaledW) / 2
        let ty = (targetSize.height - scaledH) / 2

        // Correct any origin shift introduced by the preferredTransform, then scale and center.
        var t = preferredTransform
        t.tx -= transformedRect.origin.x
        t.ty -= transformedRect.origin.y
        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        t.tx += tx
        t.ty += ty
        return t
    }

    /// Drives the AVAssetReader → AVAssetWriter encode loop using Swift concurrency.
    ///
    /// Video and audio tracks are consumed concurrently via a structured task group.
    /// Providers suspend until the next buffer is available; receivers suspend until
    /// the encoder is ready to accept more data.
    private static func encodeLoop(
        videoProvider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>,
        videoReceiver: AVAssetWriterInput.SampleBufferReceiver,
        audioProvider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>?,
        audioReceiver: AVAssetWriterInput.SampleBufferReceiver?,
        reader: AVAssetReader,
        writer: AVAssetWriter,
        durationSeconds: Double,
        progress: (@Sendable (Float) -> Void)?
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Video track
            group.addTask {
                while let buffer = try await videoProvider.next() {
                    if durationSeconds > 0 {
                        let p = Float(buffer.presentationTimeStamp.seconds / durationSeconds)
                        progress?(max(0, min(p, 1)))
                    }
                    try await videoReceiver.append(buffer)
                }
                videoReceiver.finish()
            }

            // Audio track (optional — not all video files have audio)
            if let audioProvider, let audioReceiver {
                group.addTask {
                    while let buffer = try await audioProvider.next() {
                        try await audioReceiver.append(buffer)
                    }
                    audioReceiver.finish()
                }
            }

            try await group.waitForAll()
        }

        if reader.status == .failed {
            throw reader.error ?? TranscoderError.exportFailed("Asset read failed")
        }
        if writer.status == .failed {
            throw writer.error ?? TranscoderError.exportFailed("Asset write failed")
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        if writer.status == .failed {
            throw writer.error ?? TranscoderError.exportFailed("Finish writing failed")
        }
    }

    // MARK: - Filename helpers

    /// Produces a new filename with the resolution token updated and the extension set to `.mp4`.
    ///
    /// Examples:
    ///   `abc-Movie.mkv`       → `abc-Movie 1080p.mp4`  (no existing token → appended)
    ///   `abc-Movie 2160p.mkv` → `abc-Movie 1080p.mp4`  (token replaced)
    static func updatedFilename(original: String, resolution: TranscodeResolution) -> String {
        let stem = URL(filePath: original).deletingPathExtension().lastPathComponent
        let regex = /\b(480p|720p|1080p|2160p|4[Kk])\b/.ignoresCase()
        if stem.contains(regex) {
            return "\(stem.replacing(regex, with: resolution.label)).mp4"
        }
        return "\(stem) \(resolution.label).mp4"
    }
}
#endif // os(macOS)
