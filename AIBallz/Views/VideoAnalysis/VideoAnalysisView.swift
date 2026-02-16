import SwiftUI
import PhotosUI
import SwiftData

struct VideoAnalysisView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var authManager: AuthManager
    @Query(sort: \ShotRecord.timestamp, order: .forward) private var shotRecords: [ShotRecord]

    @State private var selectedVideo: PhotosPickerItem?
    @State private var showUploadInfoAlert = false
    @State private var hydratedFromStorage = false
    @State private var lastPersistedShotCount = 0
    @State private var lastPersistedMakeCount = 0

    @StateObject private var camera = CameraController()
    @StateObject private var pose = PoseEstimator()
    @StateObject private var detector = BallHoopDetector()
    private let feedbackManager = FeedbackManager()

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Shot Analysis")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)

                Text("Record or upload a video for instant feedback")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 50)

            ZStack {
                if camera.isAuthorized {
                    CameraPreview(session: camera.session)
                    HUDOverlay(detector: detector, pose: pose)
                } else {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.gray.opacity(0.2))
                        .overlay(
                            VStack(spacing: 16) {
                                Image(systemName: "video.fill")
                                    .font(.system(size: 60))
                                    .foregroundColor(.red)
                                Text("Camera Not Authorized")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                            }
                        )
                }
            }
            .frame(height: 400)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal)

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
                .disabled(!camera.isAuthorized)

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
            }
            .padding(.horizontal)
        }
        .onAppear {
            hydrateDetectorFromStorageIfNeeded()
            configureVisionPipelines()
            camera.startSession()
        }
        .onDisappear {
            camera.stopSession()
            camera.sampleBufferHandler = nil
        }
        .onChange(of: selectedVideo) { _, newValue in
            guard newValue != nil else { return }
            selectedVideo = nil
            showUploadInfoAlert = true
        }
        .onChange(of: detector.shots) { _, newShots in
            persistShotChanges(newShots: newShots)
        }
        .alert("Upload Flow Not Connected Yet", isPresented: $showUploadInfoAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Video upload UI is present, but upload analysis is not wired yet.")
        }
    }

    private func configureVisionPipelines() {
        let cameraPosition = camera.activeCameraPosition
        detector.setCameraPosition(cameraPosition)
        pose.setCameraPosition(cameraPosition)

        camera.sampleBufferHandler = { buffer in
            pose.process(sampleBuffer: buffer)
            detector.process(sampleBuffer: buffer)
        }
    }

    private func hydrateDetectorFromStorageIfNeeded() {
        guard !hydratedFromStorage else { return }

        let totalShots = shotRecords.count
        let totalMakes = shotRecords.filter(\.isMake).count

        lastPersistedShotCount = totalShots
        lastPersistedMakeCount = totalMakes
        detector.restoreCounters(shots: totalShots, makes: totalMakes)
        hydratedFromStorage = true
    }

    private func persistShotChanges(newShots: Int) {
        guard hydratedFromStorage else { return }
        guard newShots >= 0 else { return }
        var createdShots: [ShotRecord] = []

        if newShots > lastPersistedShotCount {
            let createdCount = newShots - lastPersistedShotCount
            let makeDelta = max(0, detector.makes - lastPersistedMakeCount)
            let makesToMark = min(makeDelta, createdCount)
            let makeThreshold = createdCount - makesToMark

            for index in 0..<createdCount {
                let isMake = index >= makeThreshold
                let shotIndex = lastPersistedShotCount + index + 1
                let shot = ShotRecord(
                    isMake: isMake,
                    shotIndex: shotIndex,
                    llmFormFeedback: ShotRecord.pendingFeedbackText
                )
                modelContext.insert(shot)
                createdShots.append(shot)
            }

            guard saveModelContext() else { return }
        }

        lastPersistedShotCount = newShots
        lastPersistedMakeCount = max(0, detector.makes)

        guard !createdShots.isEmpty else { return }
        let poseSnapshot = pose.currentPoseWindow()
        let detectionSnapshot = detector.currentDetectionWindow()

        for shot in createdShots {
            requestFeedbackForShot(
                shot,
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

#Preview {
    VideoAnalysisView()
        .environmentObject(AuthManager())
}
