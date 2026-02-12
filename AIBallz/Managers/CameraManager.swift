import Foundation
import AVFoundation
import Photos

final class CameraController: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isAuthorized = false

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let movieOutput = AVCaptureMovieFileOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?

    var sampleBufferHandler: ((CMSampleBuffer) -> Void)?
    var activeCameraPosition: AVCaptureDevice.Position { videoDeviceInput?.device.position ?? .back }

    override init() {
        super.init()
        checkAuthorization()
    }

    private func checkAuthorization() {
        func handleStatus(_ status: AVAuthorizationStatus) {
            if status == .authorized {
                self.isAuthorized = true
                self.configureSession()
            } else {
                self.isAuthorized = false
            }
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            handleStatus(.authorized)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { handleStatus(granted ? .authorized : .denied) }
            }
        default:
            isAuthorized = false
        }
    }

    private func configureSession() {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .high

            // Back camera input
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    if self.session.canAddInput(input) {
                        self.session.addInput(input)
                        self.videoDeviceInput = input
                    }
                    try device.lockForConfiguration()
                    if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 30 }) {
                        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                    }
                    device.unlockForConfiguration()
                } catch {
                    print("Video input/config error:", error)
                }
            }

            // Recording output
            if self.session.canAddOutput(self.movieOutput) {
                self.session.addOutput(self.movieOutput)
            }

            // Live frame output (for Vision)
            self.videoDataOutput.alwaysDiscardsLateVideoFrames = true
            self.videoDataOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            ]
            let outputQueue = DispatchQueue(label: "camera.video.output.queue")
            self.videoDataOutput.setSampleBufferDelegate(self, queue: outputQueue)
            if self.session.canAddOutput(self.videoDataOutput) {
                self.session.addOutput(self.videoDataOutput)
            }

            // Keep processing and recording in portrait to match the UI preview.
            if let c1 = self.videoDataOutput.connection(with: .video) {
                self.applyPortraitRotation(to: c1)
            }
            if let c2 = self.movieOutput.connection(with: .video) {
                self.applyPortraitRotation(to: c2)
            }

            self.session.commitConfiguration()
            self.startSession()
        }
    }

    func startSession() {
        sessionQueue.async {
            guard !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stopSession() {
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func startRecording() {
        guard !movieOutput.isRecording else { return }
        if let c = movieOutput.connection(with: .video) {
            applyPortraitRotation(to: c)
        }
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        movieOutput.startRecording(to: fileURL, recordingDelegate: self)
        DispatchQueue.main.async { self.isRecording = true }
    }

    func stopRecording() {
        guard movieOutput.isRecording else { return }
        movieOutput.stopRecording()
        DispatchQueue.main.async { self.isRecording = false }
    }

    private func applyPortraitRotation(to connection: AVCaptureConnection) {
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        if let error = error { print("Recording error:", error) }
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputFileURL)
            }) { _, err in
                if let err = err { print("Save error:", err) }
                try? FileManager.default.removeItem(at: outputFileURL)
            }
        }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        sampleBufferHandler?(sampleBuffer)
    }
}
