@preconcurrency import AVFoundation
import Foundation

final class VideoFileAnalyzer {
    struct Summary: Equatable {
        let durationSeconds: Double
        let totalFramesRead: Int
        let sampledFramesProcessed: Int
    }

    enum AnalyzerError: LocalizedError {
        case missingVideoTrack
        case unableToCreateReader
        case readerStartFailed
        case readerFailed(reason: String)
        case invalidDuration

        var errorDescription: String? {
            switch self {
            case .missingVideoTrack:
                return "Selected item does not contain a video track."
            case .unableToCreateReader:
                return "Unable to create a reader for the selected video."
            case .readerStartFailed:
                return "Unable to start reading the selected video."
            case .readerFailed(let reason):
                return "Video analysis failed: \(reason)"
            case .invalidDuration:
                return "Video duration is invalid or unsupported."
            }
        }
    }

    func analyzeVideo(
        at url: URL,
        targetFPS: Double,
        synchronizeToTimeline: Bool = true,
        progressHandler: @escaping (Double) -> Void,
        frameHandler: @escaping (AnalysisFrame) -> Void
    ) async throws -> Summary {
        let cappedTargetFPS = max(1, min(targetFPS, 60))
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw AnalyzerError.missingVideoTrack }

        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw AnalyzerError.invalidDuration
        }

        let preferredTransform = try await track.load(.preferredTransform)
        let orientation = AnalysisFrameGeometry.videoExifOrientation(from: preferredTransform)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard let reader = try? AVAssetReader(asset: asset) else {
                        throw AnalyzerError.unableToCreateReader
                    }

                    let outputSettings: [String: Any] = [
                        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
                    ]
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
                    output.alwaysCopiesSampleData = false

                    guard reader.canAdd(output) else {
                        throw AnalyzerError.unableToCreateReader
                    }
                    reader.add(output)

                    guard reader.startReading() else {
                        throw AnalyzerError.readerStartFailed
                    }

                    let frameInterval = 1.0 / cappedTargetFPS
                    var nextAcceptedTimestamp = 0.0
                    var firstSampledTimestamp: Double?
                    var analysisStartUptime: TimeInterval?

                    var totalFrames = 0
                    var sampledFrames = 0

                    while reader.status == .reading {
                        guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
                        totalFrames += 1

                        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                        let seconds = CMTimeGetSeconds(presentation)
                        guard seconds.isFinite else { continue }

                        if seconds + 0.000_1 < nextAcceptedTimestamp {
                            progressHandler(min(max(seconds / durationSeconds, 0), 1))
                            continue
                        }
                        nextAcceptedTimestamp = seconds + frameInterval

                        if synchronizeToTimeline {
                            if firstSampledTimestamp == nil {
                                firstSampledTimestamp = seconds
                                analysisStartUptime = ProcessInfo.processInfo.systemUptime
                            }

                            if let firstSampledTimestamp, let analysisStartUptime {
                                let targetElapsed = max(0, seconds - firstSampledTimestamp)
                                let targetUptime = analysisStartUptime + targetElapsed
                                let delay = targetUptime - ProcessInfo.processInfo.systemUptime
                                if delay > 0 {
                                    Thread.sleep(forTimeInterval: delay)
                                }
                            }
                        }

                        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
                        let frame = AnalysisFrameGeometry.fileFrame(
                            pixelBuffer: pixelBuffer,
                            timestamp: seconds,
                            orientation: orientation
                        )

                        frameHandler(frame)
                        sampledFrames += 1
                        progressHandler(min(max(seconds / durationSeconds, 0), 1))
                    }

                    let summary: Summary
                    switch reader.status {
                    case .completed, .reading:
                        progressHandler(1)
                        summary = Summary(
                            durationSeconds: durationSeconds,
                            totalFramesRead: totalFrames,
                            sampledFramesProcessed: sampledFrames
                        )
                    case .failed:
                        throw AnalyzerError.readerFailed(
                            reason: reader.error?.localizedDescription ?? "Unknown reader error"
                        )
                    case .cancelled:
                        throw CancellationError()
                    case .unknown:
                        throw AnalyzerError.readerFailed(reason: "Reader status unknown")
                    @unknown default:
                        throw AnalyzerError.readerFailed(reason: "Unhandled reader status")
                    }

                    continuation.resume(returning: summary)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
