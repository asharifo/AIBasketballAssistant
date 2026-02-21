import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct VideoAnalysisView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var authManager: AuthManager
    @Query(sort: \ShotRecord.timestamp, order: .forward) private var shotRecords: [ShotRecord]

    @State private var selectedVideo: PhotosPickerItem?
    @State private var uploadState: UploadAnalysisState = .idle
    @State private var uploadTask: Task<Void, Never>?
    @State private var lastPersistedEventCount = 0

    @StateObject private var camera = CameraController()
    @StateObject private var pose: PoseEstimator
    @StateObject private var detector: BallHoopDetector

    private let analysisEngine: ShotAnalysisEngine
    private let videoFileAnalyzer = VideoFileAnalyzer()
    private let feedbackManager = FeedbackManager()

    private enum UploadAnalysisState: Equatable {
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

    init() {
        let pose = PoseEstimator()
        let detector = BallHoopDetector()
        _pose = StateObject(wrappedValue: pose)
        _detector = StateObject(wrappedValue: detector)
        analysisEngine = ShotAnalysisEngine(pose: pose, detector: detector)
    }

    var body: some View {
        VStack(spacing: 20) {
            headerSection
            previewSection
            controlsSection
            uploadStatusSection
        }
        .padding(.bottom, 12)
        .onAppear {
            startLivePipeline(resetSession: true)
        }
        .onDisappear {
            uploadTask?.cancel()
            stopLivePipeline()
            analysisEngine.resetSession()
            lastPersistedEventCount = 0
        }
        .onChange(of: selectedVideo) { _, newValue in
            guard let item = newValue else { return }
            selectedVideo = nil
            beginUploadAnalysis(item: item)
        }
        .onChange(of: detector.shotEvents.count) { _, _ in
            persistPendingShotEvents()
        }
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            Text("Shot Analysis")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(.primary)

            Text("Record or upload a video for shot detection and feedback")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Text("Session: \(detector.shots) shots • \(detector.makes) makes")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(.top, 8)
    }

    private var previewSection: some View {
        ZStack {
            if camera.isAuthorized {
                CameraPreview(session: camera.session)
                HUDOverlay(detector: detector, pose: pose)
            } else {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.gray.opacity(0.2))
                    .overlay {
                        VStack(spacing: 14) {
                            Image(systemName: "video.slash.fill")
                                .font(.system(size: 54))
                                .foregroundColor(.red)
                            Text("Camera Not Authorized")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Button("Open Settings") {
                                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                                openURL(url)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding()
                    }
            }

            uploadOverlay
        }
        .frame(height: 400)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal)
    }

    @ViewBuilder
    private var uploadOverlay: some View {
        switch uploadState {
        case .idle:
            EmptyView()
        case .loading:
            overlayCard {
                ProgressView()
                    .progressViewStyle(.circular)
                Text("Preparing video upload...")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        case .analyzing(let progress):
            overlayCard {
                VStack(spacing: 10) {
                    ProgressView(value: progress)
                        .tint(.orange)
                    Text("Analyzing upload: \(Int(progress * 100))%")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
        case .completed(let summary):
            overlayCard {
                VStack(spacing: 8) {
                    Text("Upload Analysis Complete")
                        .font(.headline)
                    Text("Processed \(summary.sampledFramesProcessed) frames from \(String(format: "%.1f", summary.durationSeconds))s video.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        case .failed(let message):
            overlayCard {
                VStack(spacing: 8) {
                    Text("Upload Analysis Failed")
                        .font(.headline)
                        .foregroundColor(.red)
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private func overlayCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack {
            Spacer()
            content()
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
    }

    private var controlsSection: some View {
        HStack(spacing: 16) {
            Button {
                camera.isRecording ? camera.stopRecording() : camera.startRecording()
            } label: {
                HStack {
                    Image(systemName: camera.isRecording ? "stop.fill" : "camera.fill")
                    Text(camera.isRecording ? "Stop" : "Record Shot")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(camera.isRecording ? .red : .orange)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!camera.isAuthorized || uploadState.isBusy)

            PhotosPicker(selection: $selectedVideo, matching: .videos) {
                HStack {
                    Image(systemName: "photo.fill")
                    Text("Upload Video")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(.blue)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(uploadState.isBusy)
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var uploadStatusSection: some View {
        if !detector.lastShotDebugSummary.isEmpty {
            Text(detector.lastShotDebugSummary)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private func startLivePipeline(resetSession: Bool) {
        if resetSession {
            analysisEngine.resetSession()
            lastPersistedEventCount = 0
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

    private func beginUploadAnalysis(item: PhotosPickerItem) {
        uploadTask?.cancel()

        uploadTask = Task {
            await runUploadAnalysis(for: item)
        }
    }

    @MainActor
    private func runUploadAnalysis(for item: PhotosPickerItem) async {
        if camera.isRecording {
            camera.stopRecording()
        }
        stopLivePipeline()
        analysisEngine.resetSession()
        lastPersistedEventCount = 0
        uploadState = .loading

        let tempURL: URL
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw UploadFlowError.unableToLoadAsset
            }

            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            try data.write(to: url, options: [.atomic])
            tempURL = url
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
                progressHandler: { progress in
                    Task { @MainActor in
                        self.uploadState = .analyzing(progress: progress)
                    }
                },
                frameHandler: { frame in
                    self.analysisEngine.processUploadedFrame(frame)
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

    private func persistPendingShotEvents() {
        let events = detector.shotEvents
        if events.count < lastPersistedEventCount {
            lastPersistedEventCount = 0
        }

        guard lastPersistedEventCount < events.count else { return }
        let newEvents = Array(events[lastPersistedEventCount..<events.count])
        lastPersistedEventCount = events.count

        persistShotEvents(newEvents)
    }

    private func persistShotEvents(_ events: [DetectedShotEvent]) {
        guard !events.isEmpty else { return }

        var pendingFeedbackRequests: [(shot: ShotRecord, event: DetectedShotEvent)] = []
        var nextIndex = (shotRecords.map(\.shotIndex).max() ?? 0) + 1

        for event in events {
            let shot = ShotRecord(
                timestamp: Date(),
                isMake: event.isMake,
                shotIndex: nextIndex,
                llmFormFeedback: ShotRecord.pendingFeedbackText
            )
            nextIndex += 1

            modelContext.insert(shot)
            pendingFeedbackRequests.append((shot, event))
        }

        guard saveModelContext() else { return }

        for request in pendingFeedbackRequests {
            let poseSnapshot = pose.poseWindowSlice(around: request.event.timestamp)
            let detectionSnapshot = detector.detectionWindowSlice(around: request.event.timestamp)

            requestFeedbackForShot(
                request.shot,
                poseSnapshot: poseSnapshot,
                detectionSnapshot: detectionSnapshot
            )
        }
    }

    private func requestFeedbackForShot(
        _ shot: ShotRecord,
        poseSnapshot: [PoseFrame],
        detectionSnapshot: [BestDetectionFrame]
    ) {
        Task {
            do {
                let accessToken = await authManager.validAccessTokenIfAvailable()
                let feedback = try await feedbackManager.requestFormFeedback(
                    shot: shot,
                    poseWindow: poseSnapshot,
                    detectionWindow: detectionSnapshot,
                    bearerToken: accessToken
                )
                await MainActor.run {
                    shot.llmFormFeedback = feedback
                    _ = saveModelContext()
                }
            } catch {
                await MainActor.run {
                    if shot.llmFormFeedback == ShotRecord.pendingFeedbackText {
                        shot.llmFormFeedback = "Feedback unavailable: \(error.localizedDescription)"
                        _ = saveModelContext()
                    }
                }
            }
        }
    }

    private func saveModelContext() -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            print("SwiftData save error: \(error)")
            return false
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

#Preview {
    VideoAnalysisView()
        .environmentObject(AuthManager())
}
