import AVFoundation
import Foundation
import PhotosUI
import SwiftData
import SwiftUI

@MainActor
final class VideoAnalysisViewModel: ObservableObject {
    enum UploadAnalysisState: Equatable {
        case idle
        case loading
        case analyzing(progress: Double)
        case completed(VideoFileAnalyzer.Summary)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .loading, .analyzing:
                return true
            case .idle, .completed, .failed:
                return false
            }
        }
    }

    @Published private(set) var uploadState: UploadAnalysisState = .idle
    @Published private(set) var uploadPreviewPlayer: AVPlayer?

    let camera: CameraController
    let pose: PoseEstimator
    let detector: BallHoopDetector

    private let analysisEngine: ShotAnalysisEngine
    private let videoFileAnalyzer: VideoFileAnalyzer
    private let feedbackManager: FeedbackManager

    private var shotRepository: ShotRepository?
    private var authManager: AuthManager?
    private var uploadTask: Task<Void, Never>?
    private var uploadPreviewLooper: AVPlayerLooper?
    private var hasStartedUploadPreviewPlayback = false
    private var persistedEventIDs: Set<UUID> = []
    private var pendingEventIDs: Set<UUID> = []
    private var pendingShotEvents: [DetectedShotEvent] = []

    init(
        camera: CameraController = CameraController(),
        pose: PoseEstimator = PoseEstimator(),
        detector: BallHoopDetector = BallHoopDetector(),
        videoFileAnalyzer: VideoFileAnalyzer = VideoFileAnalyzer(),
        feedbackManager: FeedbackManager = FeedbackManager()
    ) {
        self.camera = camera
        self.pose = pose
        self.detector = detector
        self.videoFileAnalyzer = videoFileAnalyzer
        self.feedbackManager = feedbackManager
        self.analysisEngine = ShotAnalysisEngine(pose: pose, detector: detector)

        detector.onShotEvent = { [weak self] event in
            Task.detached { @MainActor [weak self] in
                self?.handleDetectedShotEvent(event)
            }
        }
    }

    deinit {
        detector.onShotEvent = nil
    }

    func configure(modelContext: ModelContext, authManager: AuthManager) {
        shotRepository = ShotRepository(modelContext: modelContext)
        self.authManager = authManager
        flushPendingShotEventsIfNeeded()
    }

    func start() {
        startLivePipeline(resetSession: true)
    }

    func stop() {
        uploadTask?.cancel()
        stopLivePipeline()
        analysisEngine.resetSession()
        clearUploadPreview()
        persistedEventIDs.removeAll()
        pendingEventIDs.removeAll()
        pendingShotEvents.removeAll()
        uploadState = .idle
    }

    func beginUploadAnalysis(item: PhotosPickerItem) {
        uploadTask?.cancel()
        uploadTask = Task { [weak self] in
            await self?.runUploadAnalysis(for: item)
        }
    }

    private func startLivePipeline(resetSession: Bool) {
        if resetSession {
            analysisEngine.resetSession()
            clearUploadPreview()
            persistedEventIDs.removeAll()
            pendingEventIDs.removeAll()
            pendingShotEvents.removeAll()
        }

        let engine = analysisEngine
        camera.sampleBufferHandler = { [weak camera] buffer in
            let cameraPosition = camera?.activeCameraPosition ?? .back
            engine.processLiveSampleBuffer(buffer, cameraPosition: cameraPosition)
        }
        camera.startSession()
    }

    private func stopLivePipeline() {
        camera.stopSession()
        camera.sampleBufferHandler = nil
    }

    private func runUploadAnalysis(for item: PhotosPickerItem) async {
        if camera.isRecording {
            camera.stopRecording()
        }
        stopLivePipeline()
        analysisEngine.resetSession()
        clearUploadPreview()
        persistedEventIDs.removeAll()
        pendingEventIDs.removeAll()
        pendingShotEvents.removeAll()
        uploadState = .loading

        let tempURL: URL
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw UploadFlowError.unableToLoadAsset
            }

            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            try data.write(to: url, options: Data.WritingOptions.atomic)
            tempURL = url
            configureUploadPreview(with: tempURL)
        } catch {
            uploadState = .failed(error.localizedDescription)
            startLivePipeline(resetSession: true)
            return
        }

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        do {
            uploadState = .analyzing(progress: 0)

            let summary = try await videoFileAnalyzer.analyzeVideo(
                at: tempURL,
                targetFPS: 15,
                synchronizeToTimeline: true,
                progressHandler: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.startUploadPreviewIfNeeded()
                        self?.uploadState = .analyzing(progress: progress)
                    }
                },
                frameHandler: { [weak self] frame in
                    self?.analysisEngine.processUploadedFrame(frame)
                }
            )

            if Task.isCancelled {
                uploadState = .idle
            } else {
                uploadState = .completed(summary)
            }
        } catch is CancellationError {
            uploadState = .idle
        } catch {
            uploadState = .failed(error.localizedDescription)
        }

        startLivePipeline(resetSession: true)
    }

    private func configureUploadPreview(with url: URL) {
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = true
        queuePlayer.actionAtItemEnd = .none

        let item = AVPlayerItem(url: url)
        uploadPreviewLooper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        hasStartedUploadPreviewPlayback = false
        uploadPreviewPlayer = queuePlayer
        queuePlayer.pause()
    }

    private func clearUploadPreview() {
        uploadPreviewPlayer?.pause()
        uploadPreviewPlayer?.replaceCurrentItem(with: nil)
        uploadPreviewLooper = nil
        uploadPreviewPlayer = nil
        hasStartedUploadPreviewPlayback = false
    }

    private func startUploadPreviewIfNeeded() {
        guard hasStartedUploadPreviewPlayback == false else { return }
        hasStartedUploadPreviewPlayback = true
        uploadPreviewPlayer?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        uploadPreviewPlayer?.play()
    }

    private func handleDetectedShotEvent(_ event: DetectedShotEvent) {
        flushPendingShotEventsIfNeeded()

        guard !persistedEventIDs.contains(event.id), !pendingEventIDs.contains(event.id) else {
            return
        }

        guard let repository = shotRepository else {
            enqueuePending(event)
            return
        }

        if persistShotEvent(event, using: repository) == false {
            enqueuePending(event)
        }
    }

    private func flushPendingShotEventsIfNeeded() {
        guard let repository = shotRepository, !pendingShotEvents.isEmpty else { return }

        let pending = pendingShotEvents
        pendingShotEvents.removeAll()
        pendingEventIDs.removeAll()

        for event in pending {
            if persistShotEvent(event, using: repository) == false {
                enqueuePending(event)
            }
        }
    }

    private func enqueuePending(_ event: DetectedShotEvent) {
        guard pendingEventIDs.insert(event.id).inserted else { return }
        pendingShotEvents.append(event)
    }

    @discardableResult
    private func persistShotEvent(
        _ event: DetectedShotEvent,
        using repository: ShotRepository
    ) -> Bool {
        do {
            let persisted = try repository.persistShot(isMake: event.isMake)
            persistedEventIDs.insert(event.id)
            scheduleFeedback(for: persisted, event: event)
            return true
        } catch {
            print("Shot persistence error: \(error)")
            return false
        }
    }

    private func scheduleFeedback(
        for persistedShot: ShotRepository.PersistedShot,
        event: DetectedShotEvent
    ) {
        let poseSnapshot = pose.poseWindowSlice(around: event.timestamp)
        let detectionSnapshot = detector.detectionWindowSlice(around: event.timestamp)

        let shotInput = FeedbackShotInput(
            shotIndex: persistedShot.shotIndex,
            isMake: persistedShot.isMake,
            timestamp: persistedShot.timestamp
        )

        Task { @MainActor [weak self] in
            guard let self, let repository = self.shotRepository else { return }

            do {
                let accessToken = await self.authManager?.validAccessTokenIfAvailable()
                let feedback = try await self.feedbackManager.requestFormFeedback(
                    shot: shotInput,
                    poseWindow: poseSnapshot,
                    detectionWindow: detectionSnapshot,
                    bearerToken: accessToken
                )
                try repository.updateFeedback(
                    forShotIndex: persistedShot.shotIndex,
                    feedback: feedback
                )
            } catch {
                do {
                    let fallback = "Feedback unavailable: \(error.localizedDescription)"
                    try repository.updateFeedback(
                        forShotIndex: persistedShot.shotIndex,
                        feedback: fallback
                    )
                } catch {
                    print("Feedback update error: \(error)")
                }
            }
        }
    }
}

private enum UploadFlowError: LocalizedError {
    case unableToLoadAsset

    var errorDescription: String? {
        switch self {
        case .unableToLoadAsset:
            return "Unable to load selected video from the photo library."
        }
    }
}
