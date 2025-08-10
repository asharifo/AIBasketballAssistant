import SwiftUI
import PhotosUI

struct VideoAnalysisView: View {
    @State private var selectedVideo: PhotosPickerItem?
    @StateObject private var camera = CameraController()
    @StateObject private var pose = PoseEstimator()

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Shot Analysis")
                    .font(.largeTitle).fontWeight(.bold)
                    .foregroundColor(.primary)
                Text("Record or upload a video for instant feedback")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            ZStack {
                if camera.isAuthorized {
                    CameraPreview(session: camera.session)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                } else {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.gray.opacity(0.2))
                        .overlay(
                            VStack(spacing: 16) {
                                Image(systemName: "video.fill")
                                    .font(.system(size: 60))
                                    .foregroundColor(.orange)
                                Text("Camera Not Authorized")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                            }
                        )
                }
            }
            .frame(height: 400)
            .padding(.horizontal)
            .onAppear {
                camera.sampleBufferHandler = { buffer in
                    pose.process(sampleBuffer: buffer)
                }
                camera.startSession()
            }
            .onDisappear {
                camera.stopSession()
                camera.sampleBufferHandler = nil
            }

            // Simple debug readout to confirm tracking (optional; remove later)
            VStack(spacing: 6) {
                Text("Body joints: \(pose.bodyJoints.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Hands detected: \(pose.hands.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

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
    }
}

#Preview { VideoAnalysisView() }



