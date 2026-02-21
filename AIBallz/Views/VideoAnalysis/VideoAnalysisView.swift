import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct VideoAnalysisView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var authManager: AuthManager

    @State private var selectedVideo: PhotosPickerItem?
    @StateObject private var viewModel = VideoAnalysisViewModel()

    var body: some View {
        VStack(spacing: 20) {
            headerSection
            previewSection
            controlsSection
            statusSection
        }
        .padding(.bottom, 12)
        .onAppear {
            viewModel.configure(modelContext: modelContext, authManager: authManager)
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
        .onChange(of: selectedVideo) { _, newValue in
            guard let item = newValue else { return }
            selectedVideo = nil
            viewModel.beginUploadAnalysis(item: item)
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

            Text("Session: \(viewModel.detector.shots) shots • \(viewModel.detector.makes) makes")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(.top, 8)
    }

    private var previewSection: some View {
        ZStack {
            if viewModel.camera.isAuthorized {
                CameraPreview(session: viewModel.camera.session)
                HUDOverlay(detector: viewModel.detector, pose: viewModel.pose)
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
        switch viewModel.uploadState {
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
                viewModel.camera.isRecording
                    ? viewModel.camera.stopRecording()
                    : viewModel.camera.startRecording()
            } label: {
                HStack {
                    Image(systemName: viewModel.camera.isRecording ? "stop.fill" : "camera.fill")
                    Text(viewModel.camera.isRecording ? "Stop" : "Record Shot")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(viewModel.camera.isRecording ? .red : .orange)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!viewModel.camera.isAuthorized || viewModel.uploadState.isBusy)

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
            .disabled(viewModel.uploadState.isBusy)
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var statusSection: some View {
        if !viewModel.detector.lastShotDebugSummary.isEmpty {
            Text(viewModel.detector.lastShotDebugSummary)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }
}

#Preview {
    VideoAnalysisView()
        .environmentObject(AuthManager())
}
