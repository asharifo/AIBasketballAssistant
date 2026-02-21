import AVFoundation
import CoreMedia
import Foundation
import Vision

// sliding window
struct PoseFrame: Identifiable {
    let id = UUID()
    let timestamp: CFTimeInterval
    let bodyJoints: [PoseJoint: NormalizedPoint]
    let hands: [[PoseJoint: NormalizedPoint]]
    let releaseConfidence: Double
}

final class PoseEstimator: ObservableObject {
    // keypoint location dictionaries
    @Published var bodyJoints: [PoseJoint: NormalizedPoint] = [:]
    @Published var hands: [[PoseJoint: NormalizedPoint]] = []   // up to 2 hands
    @Published private(set) var releaseConfidence: Double = 0

    // sliding window of pose frames
    @Published private(set) var poseWindow: [PoseFrame] = []

    // sliding windows caps
    private let windowMaxDuration: CFTimeInterval = 5.0 // keep last 5 seconds
    private let windowMaxFrames: Int = 90               // keep last 90 frames

    private let bodyRequest = VNDetectHumanBodyPoseRequest()
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()

    private let visionQueue = DispatchQueue(label: "pose.vision.queue")
    private let throttleFPS: Double = 15
    private var lastProcessTime: CFTimeInterval = 0
    private var lastPoseFrameForRelease: PoseFrame?
    private var lastComputedReleaseConfidence: Double = 0

    private struct PoseResult {
        let bodyJoints: [PoseJoint: NormalizedPoint]
        let hands: [[PoseJoint: NormalizedPoint]]
        let releaseConfidence: Double
    }

    func process(sampleBuffer: CMSampleBuffer, cameraPosition: AVCaptureDevice.Position) {
        guard let frame = AnalysisFrameGeometry.liveFrame(from: sampleBuffer, cameraPosition: cameraPosition) else {
            return
        }

        _ = process(frame: frame, applyThrottle: true, synchronous: false)
    }

    @discardableResult
    func process(
        frame: AnalysisFrame,
        applyThrottle: Bool,
        synchronous: Bool
    ) -> Double {
        if synchronous {
            return visionQueue.sync {
                processOnVisionQueue(
                    frame: frame,
                    applyThrottle: applyThrottle,
                    publishSynchronously: true
                )
            }
        }

        let snapshot = releaseConfidence
        visionQueue.async { [weak self] in
            _ = self?.processOnVisionQueue(
                frame: frame,
                applyThrottle: applyThrottle,
                publishSynchronously: false
            )
        }
        return snapshot
    }

    func resetSession() {
        visionQueue.async { [weak self] in
            guard let self else { return }
            self.lastProcessTime = 0
            self.lastPoseFrameForRelease = nil
            self.lastComputedReleaseConfidence = 0
            DispatchQueue.main.async {
                self.bodyJoints = [:]
                self.hands = []
                self.releaseConfidence = 0
                self.poseWindow = []
            }
        }
    }

    func poseWindowSlice(around center: CFTimeInterval, radius: CFTimeInterval = 1.25) -> [PoseFrame] {
        let lower = center - radius
        let upper = center + radius
        return poseWindow.filter { $0.timestamp >= lower && $0.timestamp <= upper }
    }

    func currentPoseWindow() -> [PoseFrame] {
        poseWindow
    }

    private func processOnVisionQueue(
        frame: AnalysisFrame,
        applyThrottle: Bool,
        publishSynchronously: Bool
    ) -> Double {
        let now = frame.timestamp
        if applyThrottle, now - lastProcessTime < (1.0 / throttleFPS) {
            return lastComputedReleaseConfidence
        }
        lastProcessTime = now

        let handler = VNImageRequestHandler(
            cvPixelBuffer: frame.pixelBuffer,
            orientation: frame.orientation,
            options: [:]
        )

        do {
            try handler.perform([bodyRequest, handRequest])
            let result = makePoseResult(
                previousFrame: lastPoseFrameForRelease,
                timestamp: frame.timestamp
            )
            lastPoseFrameForRelease = PoseFrame(
                timestamp: frame.timestamp,
                bodyJoints: result.bodyJoints,
                hands: result.hands,
                releaseConfidence: result.releaseConfidence
            )
            lastComputedReleaseConfidence = result.releaseConfidence
            publish(
                result: result,
                timestamp: frame.timestamp,
                synchronously: publishSynchronously
            )
            return result.releaseConfidence
        } catch {
            let empty = PoseResult(bodyJoints: [:], hands: [], releaseConfidence: 0)
            lastPoseFrameForRelease = PoseFrame(
                timestamp: frame.timestamp,
                bodyJoints: [:],
                hands: [],
                releaseConfidence: 0
            )
            lastComputedReleaseConfidence = 0
            publish(
                result: empty,
                timestamp: frame.timestamp,
                synchronously: publishSynchronously
            )
            return 0
        }
    }

    private func makePoseResult(
        previousFrame: PoseFrame?,
        timestamp: CFTimeInterval
    ) -> PoseResult {
        var bodyOut: [PoseJoint: NormalizedPoint] = [:]
        if let bodyObs = bodyRequest.results?.first as? VNHumanBodyPoseObservation,
           let points = try? bodyObs.recognizedPoints(.all) {
            for (vnName, p) in points where p.confidence > 0.2 {
                if let j = mapVNBodyJoint(vnName) {
                    bodyOut[j] = CGPoint(x: CGFloat(p.location.x), y: CGFloat(p.location.y))
                }
            }
        }

        var handsOut: [[PoseJoint: NormalizedPoint]] = []
        if let handObs = handRequest.results {
            for obs in handObs {
                guard let pts = try? obs.recognizedPoints(.all) else { continue }
                var oneHand: [PoseJoint: NormalizedPoint] = [:]
                for (vnName, p) in pts where p.confidence > 0.2 {
                    if let j = mapVNHandJoint(vnName) {
                        oneHand[j] = CGPoint(x: CGFloat(p.location.x), y: CGFloat(p.location.y))
                    }
                }
                if !oneHand.isEmpty { handsOut.append(oneHand) }
            }
        }

        let score = estimateReleaseConfidence(
            bodyJoints: bodyOut,
            previousBodyJoints: previousFrame?.bodyJoints,
            previousTimestamp: previousFrame?.timestamp,
            currentTimestamp: timestamp
        )

        return PoseResult(bodyJoints: bodyOut, hands: handsOut, releaseConfidence: score)
    }

    private func publish(
        result: PoseResult,
        timestamp: CFTimeInterval,
        synchronously: Bool
    ) {
        let update = {
            self.bodyJoints = result.bodyJoints
            self.hands = result.hands
            self.releaseConfidence = result.releaseConfidence

            let frame = PoseFrame(
                timestamp: timestamp,
                bodyJoints: result.bodyJoints,
                hands: result.hands,
                releaseConfidence: result.releaseConfidence
            )
            self.poseWindow.append(frame)
            self.trimPoseWindow(now: timestamp)
        }

        if synchronously {
            if Thread.isMainThread {
                update()
            } else {
                DispatchQueue.main.sync(execute: update)
            }
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    private func estimateReleaseConfidence(
        bodyJoints: [PoseJoint: NormalizedPoint],
        previousBodyJoints: [PoseJoint: NormalizedPoint]?,
        previousTimestamp: CFTimeInterval?,
        currentTimestamp: CFTimeInterval
    ) -> Double {
        let left = armReleaseConfidence(
            shoulder: bodyJoints[.leftShoulder],
            elbow: bodyJoints[.leftElbow],
            wrist: bodyJoints[.leftWrist],
            previousWrist: previousBodyJoints?[.leftWrist],
            previousTimestamp: previousTimestamp,
            currentTimestamp: currentTimestamp
        )
        let right = armReleaseConfidence(
            shoulder: bodyJoints[.rightShoulder],
            elbow: bodyJoints[.rightElbow],
            wrist: bodyJoints[.rightWrist],
            previousWrist: previousBodyJoints?[.rightWrist],
            previousTimestamp: previousTimestamp,
            currentTimestamp: currentTimestamp
        )

        return max(left, right)
    }

    private func armReleaseConfidence(
        shoulder: CGPoint?,
        elbow: CGPoint?,
        wrist: CGPoint?,
        previousWrist: CGPoint?,
        previousTimestamp: CFTimeInterval?,
        currentTimestamp: CFTimeInterval
    ) -> Double {
        guard let shoulder, let elbow, let wrist else { return 0 }

        let wristAboveShoulder = normalizedScore(
            value: Double(wrist.y - shoulder.y),
            lower: 0.02,
            upper: 0.30
        )

        let wristAboveElbow = normalizedScore(
            value: Double(wrist.y - elbow.y),
            lower: 0.0,
            upper: 0.18
        )

        let elbowUnderWristX = 1.0 - normalizedScore(
            value: Double(abs(wrist.x - elbow.x)),
            lower: 0.02,
            upper: 0.24
        )

        var upwardVelocityScore = 0.0
        if let previousWrist, let previousTimestamp {
            let dt = max(0.016, currentTimestamp - previousTimestamp)
            let velocityY = Double((wrist.y - previousWrist.y) / CGFloat(dt))
            upwardVelocityScore = normalizedScore(value: velocityY, lower: 0.05, upper: 0.9)
        }

        let weighted = (0.32 * wristAboveShoulder)
            + (0.26 * wristAboveElbow)
            + (0.18 * elbowUnderWristX)
            + (0.24 * upwardVelocityScore)

        return min(max(weighted, 0), 1)
    }

    private func normalizedScore(value: Double, lower: Double, upper: Double) -> Double {
        guard upper > lower else { return 0 }
        return min(max((value - lower) / (upper - lower), 0), 1)
    }

    private func trimPoseWindow(now: CFTimeInterval) {
        // drop anything older than now - windowMaxDuration
        let cutoff = now - windowMaxDuration
        if let firstIdxToKeep = poseWindow.firstIndex(where: { $0.timestamp >= cutoff }) {
            if firstIdxToKeep > 0 { poseWindow.removeFirst(firstIdxToKeep) }
        } else if !poseWindow.isEmpty {
            // all are old
            poseWindow.removeAll()
        }

        // also enforce max frame count
        if poseWindow.count > windowMaxFrames {
            poseWindow.removeFirst(poseWindow.count - windowMaxFrames)
        }
    }
}
