import Foundation
import AVFoundation
import Photos

final class CameraController: NSObject, ObservableObject {
    enum RecordingState: Equatable {
        case idle
        case starting
        case recording
        case stopping
        case failed(String)

        var isActive: Bool {
            switch self {
            case .starting, .recording, .stopping:
                return true
            case .idle, .failed:
                return false
            }
        }
    }

    @Published private(set) var recordingState: RecordingState = .idle
    @Published var isAuthorized = false

    var isRecording: Bool { recordingState.isActive }
    var isActivelyRecording: Bool {
        if case .recording = recordingState { return true }
        return false
    }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let movieOutput = AVCaptureMovieFileOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var pendingRecordingURL: URL?

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
        switch recordingState {
        case .idle, .failed:
            break
        case .starting, .recording, .stopping:
            return
        }

        publishRecordingState(.starting)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning else {
                self.publishRecordingState(.failed("Camera session is not running."))
                return
            }
            guard !self.movieOutput.isRecording else {
                self.publishRecordingState(.recording)
                return
            }

            if let connection = self.movieOutput.connection(with: .video) {
                self.applyPortraitRotation(to: connection)
            }

            let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            self.pendingRecordingURL = fileURL
            self.movieOutput.startRecording(to: fileURL, recordingDelegate: self)
        }
    }

    func stopRecording() {
        switch recordingState {
        case .recording, .starting:
            break
        case .idle, .stopping, .failed:
            return
        }

        publishRecordingState(.stopping)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.movieOutput.isRecording else {
                self.pendingRecordingURL = nil
                self.publishRecordingState(.idle)
                return
            }
            self.movieOutput.stopRecording()
        }
    }

    private func applyPortraitRotation(to connection: AVCaptureConnection) {
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }

    private func publishRecordingState(_ newState: RecordingState) {
        DispatchQueue.main.async {
            self.recordingState = newState
        }
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        publishRecordingState(.recording)
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        if let expectedURL = pendingRecordingURL, expectedURL != outputFileURL {
            print("Recording finished for unexpected URL: \(outputFileURL.lastPathComponent)")
        }
        pendingRecordingURL = nil

        if let error {
            print("Recording error:", error)
            publishRecordingState(.failed(error.localizedDescription))
            try? FileManager.default.removeItem(at: outputFileURL)
            return
        }

        publishRecordingState(.idle)
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else {
                try? FileManager.default.removeItem(at: outputFileURL)
                return
            }
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
