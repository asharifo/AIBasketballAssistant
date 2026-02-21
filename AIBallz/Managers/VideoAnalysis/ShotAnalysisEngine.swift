import AVFoundation
import CoreMedia
import Foundation

final class ShotAnalysisEngine {
    private let pose: PoseEstimator
    private let detector: BallHoopDetector

    init(pose: PoseEstimator, detector: BallHoopDetector) {
        self.pose = pose
        self.detector = detector
    }

    func resetSession() {
        pose.resetSession()
        detector.resetSession()
    }

    func processLiveSampleBuffer(_ sampleBuffer: CMSampleBuffer, cameraPosition: AVCaptureDevice.Position) {
        guard let frame = AnalysisFrameGeometry.liveFrame(
            from: sampleBuffer,
            cameraPosition: cameraPosition
        ) else {
            return
        }

        let poseSignal = pose.process(
            frame: frame,
            applyThrottle: true,
            synchronous: false
        )

        detector.process(
            frame: frame,
            poseReleaseConfidence: poseSignal,
            source: .liveCamera,
            applyThrottle: true,
            synchronous: false
        )
    }

    func processUploadedFrame(_ frame: AnalysisFrame) {
        let poseSignal = pose.process(
            frame: frame,
            applyThrottle: false,
            synchronous: true
        )

        detector.process(
            frame: frame,
            poseReleaseConfidence: poseSignal,
            source: .uploadedVideo,
            applyThrottle: false,
            synchronous: true
        )
    }
}
