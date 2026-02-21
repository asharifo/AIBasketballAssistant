import AVFoundation
import CoreGraphics
import CoreML
import CoreMedia
import Foundation
import Vision

public enum TargetClass: String {
    case basketball = "Basketball"
    case hoop = "Basketball Hoop"
}

public enum AnalysisInputSource: String, Codable {
    case liveCamera = "live_camera"
    case uploadedVideo = "uploaded_video"
}

public struct YOLODetection: Identifiable {
    public let id = UUID()
    public let cls: TargetClass
    public let confidence: Float
    public let bbox: CGRect // Vision normalized bbox (origin = lower-left)
}

public struct BestDetectionFrame: Identifiable {
    public let id = UUID()
    public let timestamp: CFTimeInterval
    public let ball: YOLODetection?
    public let hoop: YOLODetection?
}

public struct ShotDetectionDiagnostics {
    public let reason: String
    public let poseReleaseConfidence: Double
    public let sawBallAboveRim: Bool
    public let crossingOffsetPixels: CGFloat?
    public let centeredAtRim: Bool?
    public let stayedNearCenterBelow: Bool?

    public var summary: String {
        let offsetString: String
        if let crossingOffsetPixels {
            offsetString = String(format: "%.1f", crossingOffsetPixels)
        } else {
            offsetString = "n/a"
        }

        return "reason=\(reason), pose=\(String(format: "%.2f", poseReleaseConfidence)), aboveRim=\(sawBallAboveRim), crossingOffsetPx=\(offsetString), centeredAtRim=\(centeredAtRim?.description ?? "n/a"), stayedNearCenter=\(stayedNearCenterBelow?.description ?? "n/a")"
    }
}

public struct DetectedShotEvent: Identifiable {
    public let id = UUID()
    public let timestamp: CFTimeInterval
    public let isMake: Bool
    public let confidence: Double
    public let source: AnalysisInputSource
    public let diagnostics: ShotDetectionDiagnostics

    public var debugSummary: String {
        "source=\(source.rawValue), outcome=\(isMake ? "make" : "miss"), confidence=\(String(format: "%.2f", confidence)), \(diagnostics.summary)"
    }
}

final class BallHoopDetector: NSObject, ObservableObject {
    @Published private(set) var currentBestBall: YOLODetection?
    @Published private(set) var currentBestHoop: YOLODetection?

    @Published private(set) var shots: Int = 0
    @Published private(set) var makes: Int = 0
    @Published private(set) var lastShotResultText: String = "Waiting..."
    @Published private(set) var lastShotDebugSummary: String = ""
    @Published private(set) var overlayImageSize: CGSize = .zero

    @Published private(set) var shotEvents: [DetectedShotEvent] = []
    @Published private(set) var detectionWindow: [BestDetectionFrame] = []
    private let windowMaxDuration: CFTimeInterval = 5.0
    private let windowMaxFrames: Int = 90

    private let throttleFPS: Double = 15
    private var lastProcessTime: CFTimeInterval = 0

    private let visionQueue = DispatchQueue(label: "yolo.vision.queue", qos: .userInitiated)
    private let visionQueueKey = DispatchSpecificKey<Void>()
    private let request: VNCoreMLRequest

    private var frameCount: Int = 0

    /// Pixel space (origin top-left).
    private struct TrackPoint {
        var center: CGPoint
        var frame: Int
        var timestamp: CFTimeInterval
        var w: CGFloat
        var h: CGFloat
        var conf: Float
        var isPredicted: Bool
    }

    private struct TrackState {
        var latest: TrackPoint
        var velocity: CGVector // pixels per second
        var missedTime: CFTimeInterval
    }

    private struct TrackTuning {
        let occlusionToleranceSeconds: CFTimeInterval
        let associationDistanceMultiplier: CGFloat
        let minAssociationDistance: CGFloat
        let maxSpeedPerSecond: CGFloat
        let measurementBlend: CGFloat
        let reacquireConfidence: Float
    }

    private struct TrackUpdate {
        let point: TrackPoint?
        let displayDetection: YOLODetection?
    }

    private enum ShotPhase {
        case idle
        case tracking(startTime: CFTimeInterval)
        case cooldown(untilTime: CFTimeInterval)
    }

    // Track histories (include predicted points to bridge short occlusions)
    private var ballPos: [TrackPoint] = []
    private var hoopPos: [TrackPoint] = []
    private var ballTrack: TrackState?
    private var hoopTrack: TrackState?

    private var shotPhase: ShotPhase = .idle
    private var sawBallAboveRimInAttempt = false
    private var rimCrossingX: CGFloat?
    private var rimCrossingTime: CFTimeInterval?
    private var maxPoseReleaseConfidenceInAttempt: Double = 0
    private var attemptSource: AnalysisInputSource = .liveCamera

    // Confidence thresholds
    private let hoopMinConf: Float = 0.50
    private let ballMinConf: Float = 0.30
    private let ballNearHoopMinConf: Float = 0.15

    // Shot-state tuning (time-based)
    private let noTargetTrackingTimeout: CFTimeInterval = 4.0
    private let crossingSettleTimeout: CFTimeInterval = 0.9
    private let attemptTimeout: CFTimeInterval = 3.6
    private let cooldownDuration: CFTimeInterval = 0.8

    // Velocity thresholds (pixels per second)
    private let upwardVelocityThreshold: CGFloat = -22.0
    private let strongUpwardVelocityThreshold: CGFloat = -36.0
    private let downwardVelocityThreshold: CGFloat = 22.0
    private let sidewaysEscapeVelocityThreshold: CGFloat = 12.0
    private let minPoseReleaseForArm: Double = 0.33

    // Tracking tuning
    private let ballTracking = TrackTuning(
        occlusionToleranceSeconds: 0.8,
        associationDistanceMultiplier: 3.0,
        minAssociationDistance: 28.0,
        maxSpeedPerSecond: 1650.0,
        measurementBlend: 0.78,
        reacquireConfidence: 0.60
    )

    private let hoopTracking = TrackTuning(
        occlusionToleranceSeconds: 3.0,
        associationDistanceMultiplier: 1.8,
        minAssociationDistance: 22.0,
        maxSpeedPerSecond: 300.0,
        measurementBlend: 0.60,
        reacquireConfidence: 0.70
    )

    override init() {
        let configuration = MLModelConfiguration()
        guard let generated = try? best(configuration: configuration) else {
            fatalError("Failed to initialize generated Core ML class `best`.")
        }
        guard let vnModel = try? VNCoreMLModel(for: generated.model) else {
            fatalError("Failed to create VNCoreMLModel from `best`.")
        }
        let req = VNCoreMLRequest(model: vnModel)
        req.imageCropAndScaleOption = .scaleFill
        self.request = req

        super.init()
        visionQueue.setSpecific(key: visionQueueKey, value: ())
    }

    func process(
        sampleBuffer: CMSampleBuffer,
        cameraPosition: AVCaptureDevice.Position,
        poseReleaseConfidence: Double? = nil,
        source: AnalysisInputSource = .liveCamera
    ) {
        guard let frame = AnalysisFrameGeometry.liveFrame(
            from: sampleBuffer,
            cameraPosition: cameraPosition
        ) else {
            return
        }

        process(
            frame: frame,
            poseReleaseConfidence: poseReleaseConfidence,
            source: source,
            applyThrottle: true,
            synchronous: false
        )
    }

    func process(
        frame: AnalysisFrame,
        poseReleaseConfidence: Double?,
        source: AnalysisInputSource,
        applyThrottle: Bool,
        synchronous: Bool
    ) {
        if synchronous {
            if DispatchQueue.getSpecific(key: visionQueueKey) != nil {
                processOnVisionQueue(
                    frame: frame,
                    poseReleaseConfidence: poseReleaseConfidence ?? 0,
                    source: source,
                    applyThrottle: applyThrottle,
                    publishSynchronously: true
                )
            } else {
                visionQueue.sync {
                    processOnVisionQueue(
                        frame: frame,
                        poseReleaseConfidence: poseReleaseConfidence ?? 0,
                        source: source,
                        applyThrottle: applyThrottle,
                        publishSynchronously: true
                    )
                }
            }
            return
        }

        let releaseSignal = poseReleaseConfidence ?? 0
        visionQueue.async { [weak self] in
            self?.processOnVisionQueue(
                frame: frame,
                poseReleaseConfidence: releaseSignal,
                source: source,
                applyThrottle: applyThrottle,
                publishSynchronously: false
            )
        }
    }

    func resetSession() {
        visionQueue.async { [weak self] in
            guard let self else { return }
            self.lastProcessTime = 0
            self.frameCount = 0
            self.ballPos = []
            self.hoopPos = []
            self.ballTrack = nil
            self.hoopTrack = nil
            self.shotPhase = .idle
            self.resetAttemptState()

            DispatchQueue.main.async {
                self.currentBestBall = nil
                self.currentBestHoop = nil
                self.overlayImageSize = .zero
                self.shots = 0
                self.makes = 0
                self.lastShotResultText = "Waiting..."
                self.lastShotDebugSummary = ""
                self.shotEvents = []
                self.detectionWindow = []
            }
        }
    }

    func currentDetectionWindow() -> [BestDetectionFrame] {
        detectionWindow
    }

    func detectionWindowSlice(around center: CFTimeInterval, radius: CFTimeInterval = 1.25) -> [BestDetectionFrame] {
        let lower = center - radius
        let upper = center + radius
        return detectionWindow.filter { $0.timestamp >= lower && $0.timestamp <= upper }
    }

    private func processOnVisionQueue(
        frame: AnalysisFrame,
        poseReleaseConfidence: Double,
        source: AnalysisInputSource,
        applyThrottle: Bool,
        publishSynchronously: Bool
    ) {
        if applyThrottle, frame.timestamp - lastProcessTime < (1.0 / throttleFPS) {
            return
        }
        lastProcessTime = frame.timestamp

        let pixelBuffer = frame.pixelBuffer
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: frame.orientation,
            options: [:]
        )

        let observations: [VNRecognizedObjectObservation]
        do {
            try handler.perform([request])
            observations = (request.results as? [VNRecognizedObjectObservation]) ?? []
        } catch {
            observations = []
        }

        handleResults(
            observations,
            timestamp: frame.timestamp,
            frameW: width,
            frameH: height,
            overlayImageSize: frame.orientedImageSize,
            poseReleaseConfidence: poseReleaseConfidence,
            source: source,
            publishSynchronously: publishSynchronously
        )
    }

    private func handleResults(
        _ observations: [VNRecognizedObjectObservation],
        timestamp: CFTimeInterval,
        frameW: CGFloat,
        frameH: CGFloat,
        overlayImageSize: CGSize,
        poseReleaseConfidence: Double,
        source: AnalysisInputSource,
        publishSynchronously: Bool
    ) {
        var candidatesBall: [YOLODetection] = []
        var candidatesHoop: [YOLODetection] = []

        for obs in observations {
            guard let top = obs.labels.first else { continue }
            let name = top.identifier
            let conf = top.confidence
            let rect = obs.boundingBox

            if name == TargetClass.basketball.rawValue {
                candidatesBall.append(YOLODetection(cls: .basketball, confidence: conf, bbox: rect))
            } else if name == TargetClass.hoop.rawValue {
                candidatesHoop.append(YOLODetection(cls: .hoop, confidence: conf, bbox: rect))
            }
        }

        let hoopMeasurement = candidatesHoop
            .filter { $0.confidence >= hoopMinConf }
            .max(by: { $0.confidence < $1.confidence })

        let hoopUpdate = updateTrack(
            track: &hoopTrack,
            cls: .hoop,
            measurement: hoopMeasurement,
            tuning: hoopTracking,
            frameW: frameW,
            frameH: frameH,
            frame: frameCount,
            timestamp: timestamp
        )
        if let point = hoopUpdate.point { hoopPos.append(point) }
        cleanHoopPos(now: timestamp)

        let acceptedBalls: [YOLODetection] = candidatesBall.filter { det in
            if det.confidence >= ballMinConf { return true }
            if det.confidence >= ballNearHoopMinConf {
                let center = centerPixels(fromVisionBBox: det.bbox, frameW: frameW, frameH: frameH)
                return inHoopRegion(center: center)
            }
            return false
        }

        let ballMeasurement = acceptedBalls.max(by: { $0.confidence < $1.confidence })

        let ballUpdate = updateTrack(
            track: &ballTrack,
            cls: .basketball,
            measurement: ballMeasurement,
            tuning: ballTracking,
            frameW: frameW,
            frameH: frameH,
            frame: frameCount,
            timestamp: timestamp
        )
        if let point = ballUpdate.point { ballPos.append(point) }
        cleanBallPos(now: timestamp)

        let shotEvent = shotDetection(
            now: timestamp,
            poseReleaseConfidence: poseReleaseConfidence,
            source: source
        )
        frameCount += 1

        let publishBall = ballUpdate.displayDetection
        let publishHoop = hoopUpdate.displayDetection

        let update = {
            self.currentBestBall = publishBall
            self.currentBestHoop = publishHoop
            self.overlayImageSize = overlayImageSize

            if let shotEvent {
                self.shots += 1
                if shotEvent.isMake { self.makes += 1 }
                self.lastShotResultText = shotEvent.isMake ? "Make" : "Miss"
                self.lastShotDebugSummary = shotEvent.debugSummary
                self.shotEvents.append(shotEvent)
                self.logShotEvent(shotEvent)
            }

            self.detectionWindow.append(
                BestDetectionFrame(timestamp: timestamp, ball: publishBall, hoop: publishHoop)
            )
            self.trimDetectionWindow(now: timestamp)
        }

        if publishSynchronously {
            if Thread.isMainThread {
                update()
            } else {
                DispatchQueue.main.sync(execute: update)
            }
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    // MARK: - Shot logic

    private func shotDetection(
        now: CFTimeInterval,
        poseReleaseConfidence: Double,
        source: AnalysisInputSource
    ) -> DetectedShotEvent? {
        guard let hoop = hoopPos.last, let ball = ballPos.last else {
            if case .tracking(let startTime) = shotPhase, now - startTime > noTargetTrackingTimeout {
                resetAttemptState()
                shotPhase = .idle
            }
            return nil
        }

        let rimY = hoop.center.y - 0.5 * hoop.h
        let distanceX = abs(ball.center.x - hoop.center.x)
        let nearHoopX = distanceX <= max(35.0, 3.2 * hoop.w)
        let velocityY = currentBallVelocityY() ?? 0

        switch shotPhase {
        case .idle:
            let poseSignalReady = poseReleaseConfidence >= minPoseReleaseForArm
            let strongUpwardSignal = velocityY < strongUpwardVelocityThreshold

            if nearHoopX,
               velocityY < upwardVelocityThreshold,
               ball.center.y < hoop.center.y + (2.5 * hoop.h),
               (poseSignalReady || strongUpwardSignal) {
                shotPhase = .tracking(startTime: now)
                sawBallAboveRimInAttempt = ball.center.y < rimY - (0.2 * hoop.h)
                rimCrossingX = nil
                rimCrossingTime = nil
                maxPoseReleaseConfidenceInAttempt = poseReleaseConfidence
                attemptSource = source
            }

        case .tracking(let startTime):
            maxPoseReleaseConfidenceInAttempt = max(maxPoseReleaseConfidenceInAttempt, poseReleaseConfidence)
            sawBallAboveRimInAttempt = sawBallAboveRimInAttempt || (ball.center.y < rimY - (0.2 * hoop.h))

            if rimCrossingTime == nil,
               sawBallAboveRimInAttempt,
               let crossingX = downwardRimCrossingX(rimY: rimY) {
                rimCrossingTime = now
                rimCrossingX = crossingX
            }

            if let crossingTime = rimCrossingTime, let crossingX = rimCrossingX {
                let settledBelowRim = ball.center.y > hoop.center.y + (0.85 * hoop.h)
                let crossingTimedOut = now - crossingTime > crossingSettleTimeout

                if settledBelowRim || crossingTimedOut {
                    let innerHalfWidth = max(8.0, 0.42 * hoop.w)
                    let outerHalfWidth = max(12.0, 0.68 * hoop.w)

                    let centeredAtRim = abs(crossingX - hoop.center.x) <= innerHalfWidth
                    let stayedNearCenterBelow = abs(ball.center.x - hoop.center.x) <= outerHalfWidth
                    let isMake = centeredAtRim && stayedNearCenterBelow

                    return finalizeAttempt(
                        make: isMake,
                        now: now,
                        hoopCenterX: hoop.center.x,
                        hoopWidth: hoop.w,
                        crossingX: crossingX,
                        centeredAtRim: centeredAtRim,
                        stayedNearCenterBelow: stayedNearCenterBelow,
                        poseReleaseConfidence: maxPoseReleaseConfidenceInAttempt,
                        source: attemptSource,
                        reason: "rim_crossing"
                    )
                }
            } else {
                let attemptTimedOut = now - startTime > attemptTimeout
                let descendingPastHoop = sawBallAboveRimInAttempt
                    && velocityY > downwardVelocityThreshold
                    && ball.center.y > hoop.center.y + (0.4 * hoop.h)
                let escapedSideways = distanceX > max(80.0, 4.2 * hoop.w)
                    && velocityY > sidewaysEscapeVelocityThreshold

                if attemptTimedOut || descendingPastHoop || escapedSideways {
                    if sawBallAboveRimInAttempt {
                        let reason: String
                        if attemptTimedOut {
                            reason = "attempt_timeout"
                        } else if descendingPastHoop {
                            reason = "descending_past_rim"
                        } else {
                            reason = "sideways_escape"
                        }

                        return finalizeAttempt(
                            make: false,
                            now: now,
                            hoopCenterX: hoop.center.x,
                            hoopWidth: hoop.w,
                            crossingX: rimCrossingX,
                            centeredAtRim: nil,
                            stayedNearCenterBelow: nil,
                            poseReleaseConfidence: maxPoseReleaseConfidenceInAttempt,
                            source: attemptSource,
                            reason: reason
                        )
                    }
                    resetAttemptState()
                    shotPhase = .idle
                }
            }

        case .cooldown(let untilTime):
            if now >= untilTime {
                shotPhase = .idle
            }
        }

        return nil
    }

    private func finalizeAttempt(
        make: Bool,
        now: CFTimeInterval,
        hoopCenterX: CGFloat,
        hoopWidth: CGFloat,
        crossingX: CGFloat?,
        centeredAtRim: Bool?,
        stayedNearCenterBelow: Bool?,
        poseReleaseConfidence: Double,
        source: AnalysisInputSource,
        reason: String
    ) -> DetectedShotEvent {
        let crossingOffset = crossingX.map { $0 - hoopCenterX }
        let alignmentScore: Double
        if let offset = crossingOffset {
            let maxRelevantOffset = max(12.0, 0.85 * hoopWidth)
            alignmentScore = 1.0 - min(1.0, Double(abs(offset) / maxRelevantOffset))
        } else {
            alignmentScore = 0.35
        }

        let base = make ? 0.55 : 0.28
        let confidence = min(
            max(base + (0.30 * alignmentScore) + (0.25 * poseReleaseConfidence), 0.05),
            0.99
        )

        let diagnostics = ShotDetectionDiagnostics(
            reason: reason,
            poseReleaseConfidence: poseReleaseConfidence,
            sawBallAboveRim: sawBallAboveRimInAttempt,
            crossingOffsetPixels: crossingOffset,
            centeredAtRim: centeredAtRim,
            stayedNearCenterBelow: stayedNearCenterBelow
        )

        resetAttemptState()
        shotPhase = .cooldown(untilTime: now + cooldownDuration)

        return DetectedShotEvent(
            timestamp: now,
            isMake: make,
            confidence: confidence,
            source: source,
            diagnostics: diagnostics
        )
    }

    private func resetAttemptState() {
        sawBallAboveRimInAttempt = false
        rimCrossingX = nil
        rimCrossingTime = nil
        maxPoseReleaseConfidenceInAttempt = 0
        attemptSource = .liveCamera
    }

    private func currentBallVelocityY() -> CGFloat? {
        guard ballPos.count > 1 else { return nil }
        let previous = ballPos[ballPos.count - 2]
        let current = ballPos[ballPos.count - 1]
        let deltaT = max(0.016, current.timestamp - previous.timestamp)
        return (current.center.y - previous.center.y) / CGFloat(deltaT)
    }

    private func downwardRimCrossingX(rimY: CGFloat) -> CGFloat? {
        guard ballPos.count > 1 else { return nil }
        let previous = ballPos[ballPos.count - 2]
        let current = ballPos[ballPos.count - 1]

        guard previous.center.y < rimY, current.center.y >= rimY else { return nil }
        if previous.isPredicted && current.isPredicted { return nil }

        let dy = current.center.y - previous.center.y
        guard abs(dy) > 1e-5 else { return nil }

        let t = (rimY - previous.center.y) / dy
        guard t >= 0, t <= 1 else { return nil }
        return previous.center.x + ((current.center.x - previous.center.x) * t)
    }

    // MARK: - Tracking logic

    private func updateTrack(
        track: inout TrackState?,
        cls: TargetClass,
        measurement: YOLODetection?,
        tuning: TrackTuning,
        frameW: CGFloat,
        frameH: CGFloat,
        frame: Int,
        timestamp: CFTimeInterval
    ) -> TrackUpdate {
        let measurementPoint = measurement.map {
            trackPointPixels(
                from: $0,
                frameW: frameW,
                frameH: frameH,
                frame: frame,
                timestamp: timestamp,
                predicted: false
            )
        }

        if var existing = track {
            let deltaT = max(0.016, timestamp - existing.latest.timestamp)
            let predictedCenter = projectCenter(
                from: existing.latest.center,
                velocity: existing.velocity,
                deltaTime: deltaT,
                maxSpeedPerSecond: tuning.maxSpeedPerSecond
            )

            if let measurement, let measurementPoint {
                let associationRadius = max(
                    tuning.minAssociationDistance,
                    tuning.associationDistanceMultiplier * max(existing.latest.w, existing.latest.h)
                )
                let distanceToPrediction = hypot(
                    measurementPoint.center.x - predictedCenter.x,
                    measurementPoint.center.y - predictedCenter.y
                )
                let shouldAssociate = distanceToPrediction <= associationRadius
                    || measurement.confidence >= tuning.reacquireConfidence

                if shouldAssociate {
                    let blendedCenter = CGPoint(
                        x: lerp(predictedCenter.x, measurementPoint.center.x, tuning.measurementBlend),
                        y: lerp(predictedCenter.y, measurementPoint.center.y, tuning.measurementBlend)
                    )
                    let blendedPoint = TrackPoint(
                        center: clampToFrame(blendedCenter, frameW: frameW, frameH: frameH),
                        frame: frame,
                        timestamp: timestamp,
                        w: lerp(existing.latest.w, measurementPoint.w, 0.35),
                        h: lerp(existing.latest.h, measurementPoint.h, 0.35),
                        conf: measurement.confidence,
                        isPredicted: false
                    )

                    let rawVelocity = CGVector(
                        dx: (blendedPoint.center.x - existing.latest.center.x) / CGFloat(deltaT),
                        dy: (blendedPoint.center.y - existing.latest.center.y) / CGFloat(deltaT)
                    )
                    let cappedVelocity = clampVector(rawVelocity, maxMagnitude: tuning.maxSpeedPerSecond)
                    existing.velocity = CGVector(
                        dx: (existing.velocity.dx * 0.55) + (cappedVelocity.dx * 0.45),
                        dy: (existing.velocity.dy * 0.55) + (cappedVelocity.dy * 0.45)
                    )
                    existing.latest = blendedPoint
                    existing.missedTime = 0
                    track = existing

                    return TrackUpdate(
                        point: blendedPoint,
                        displayDetection: detectionFromTrackPoint(
                            blendedPoint,
                            cls: cls,
                            frameW: frameW,
                            frameH: frameH
                        )
                    )
                }
            }

            if existing.missedTime < tuning.occlusionToleranceSeconds {
                let predictedVelocity = clampVector(existing.velocity, maxMagnitude: tuning.maxSpeedPerSecond)
                let predictedCenter = clampToFrame(
                    CGPoint(
                        x: existing.latest.center.x + (predictedVelocity.dx * CGFloat(deltaT)),
                        y: existing.latest.center.y + (predictedVelocity.dy * CGFloat(deltaT))
                    ),
                    frameW: frameW,
                    frameH: frameH
                )

                let predictedPoint = TrackPoint(
                    center: predictedCenter,
                    frame: frame,
                    timestamp: timestamp,
                    w: existing.latest.w,
                    h: existing.latest.h,
                    conf: max(0.05, existing.latest.conf * 0.85),
                    isPredicted: true
                )
                existing.latest = predictedPoint
                existing.velocity = CGVector(
                    dx: predictedVelocity.dx * 0.90,
                    dy: predictedVelocity.dy * 0.90
                )
                existing.missedTime += deltaT
                track = existing

                return TrackUpdate(
                    point: predictedPoint,
                    displayDetection: detectionFromTrackPoint(
                        predictedPoint,
                        cls: cls,
                        frameW: frameW,
                        frameH: frameH
                    )
                )
            }

            track = nil
            return TrackUpdate(point: nil, displayDetection: nil)
        }

        if let measurementPoint {
            let newTrack = TrackState(
                latest: measurementPoint,
                velocity: .zero,
                missedTime: 0
            )
            track = newTrack

            return TrackUpdate(
                point: measurementPoint,
                displayDetection: detectionFromTrackPoint(
                    measurementPoint,
                    cls: cls,
                    frameW: frameW,
                    frameH: frameH
                )
            )
        }

        return TrackUpdate(point: nil, displayDetection: nil)
    }

    private func cleanBallPos(now: CFTimeInterval) {
        if ballPos.count > 1 {
            let previous = ballPos[ballPos.count - 2]
            let current = ballPos[ballPos.count - 1]
            let deltaT = max(0.016, current.timestamp - previous.timestamp)

            if !current.isPredicted {
                let distance = hypot(current.center.x - previous.center.x, current.center.y - previous.center.y)
                let maxDistance = max(
                    max(30.0, 5.0 * max(previous.w, previous.h)),
                    ballTracking.maxSpeedPerSecond * CGFloat(deltaT) * 1.3
                )
                if distance > maxDistance {
                    _ = ballPos.popLast()
                    if var track = ballTrack {
                        track.latest = previous
                        track.velocity = .zero
                        track.missedTime = 0
                        ballTrack = track
                    }
                }
            }
        }

        trimHistory(&ballPos, maxAgeSeconds: 6.0, now: now)
    }

    private func cleanHoopPos(now: CFTimeInterval) {
        if hoopPos.count > 1 {
            let previous = hoopPos[hoopPos.count - 2]
            let current = hoopPos[hoopPos.count - 1]
            let deltaT = max(0.016, current.timestamp - previous.timestamp)

            if !current.isPredicted {
                let distance = hypot(current.center.x - previous.center.x, current.center.y - previous.center.y)
                let maxDistance = max(
                    max(20.0, 1.8 * max(previous.w, previous.h)),
                    hoopTracking.maxSpeedPerSecond * CGFloat(deltaT) * 1.3
                )
                if distance > maxDistance {
                    _ = hoopPos.popLast()
                    if var track = hoopTrack {
                        track.latest = previous
                        track.velocity = .zero
                        track.missedTime = 0
                        hoopTrack = track
                    }
                }
            }
        }

        trimHistory(&hoopPos, maxAgeSeconds: 8.0, now: now)
    }

    private func trimHistory(
        _ history: inout [TrackPoint],
        maxAgeSeconds: CFTimeInterval,
        now: CFTimeInterval
    ) {
        let cutoff = now - maxAgeSeconds
        if let firstToKeep = history.firstIndex(where: { $0.timestamp >= cutoff }) {
            if firstToKeep > 0 { history.removeFirst(firstToKeep) }
        } else if !history.isEmpty {
            history.removeAll()
        }
    }

    private func inHoopRegion(center: CGPoint) -> Bool {
        guard let hoop = (hoopTrack?.latest ?? hoopPos.last) else { return false }

        let x1 = hoop.center.x - (1.0 * hoop.w)
        let x2 = hoop.center.x + (1.0 * hoop.w)
        let y1 = hoop.center.y - (1.0 * hoop.h)
        let y2 = hoop.center.y + (0.5 * hoop.h)

        return (x1 < center.x && center.x < x2)
            && (y1 < center.y && center.y < y2)
    }

    // MARK: - Pixel conversion helpers (Vision bbox -> OpenCV-like pixel coords)

    private func trackPointPixels(
        from det: YOLODetection,
        frameW: CGFloat,
        frameH: CGFloat,
        frame: Int,
        timestamp: CFTimeInterval,
        predicted: Bool
    ) -> TrackPoint {
        let center = centerPixels(fromVisionBBox: det.bbox, frameW: frameW, frameH: frameH)
        let size = sizePixels(fromVisionBBox: det.bbox, frameW: frameW, frameH: frameH)
        return TrackPoint(
            center: center,
            frame: frame,
            timestamp: timestamp,
            w: size.width,
            h: size.height,
            conf: det.confidence,
            isPredicted: predicted
        )
    }

    private func centerPixels(fromVisionBBox bbox: CGRect, frameW: CGFloat, frameH: CGFloat) -> CGPoint {
        let cxN = bbox.midX
        let cyN = bbox.midY
        let cx = cxN * frameW
        let cy = (1.0 - cyN) * frameH
        return CGPoint(x: cx, y: cy)
    }

    private func sizePixels(fromVisionBBox bbox: CGRect, frameW: CGFloat, frameH: CGFloat) -> CGSize {
        CGSize(width: bbox.width * frameW, height: bbox.height * frameH)
    }

    private func detectionFromTrackPoint(
        _ point: TrackPoint,
        cls: TargetClass,
        frameW: CGFloat,
        frameH: CGFloat
    ) -> YOLODetection? {
        guard frameW > 0, frameH > 0 else { return nil }

        let widthPx = max(2.0, point.w)
        let heightPx = max(2.0, point.h)
        let xMinPx = point.center.x - (widthPx / 2.0)
        let yTopPx = point.center.y - (heightPx / 2.0)

        var x = xMinPx / frameW
        var y = 1.0 - ((yTopPx + heightPx) / frameH) // lower-left origin
        var w = widthPx / frameW
        var h = heightPx / frameH

        x = clamp(x, lower: 0.0, upper: 1.0)
        y = clamp(y, lower: 0.0, upper: 1.0)
        w = clamp(w, lower: 0.0, upper: 1.0 - x)
        h = clamp(h, lower: 0.0, upper: 1.0 - y)

        guard w > 0, h > 0 else { return nil }
        return YOLODetection(
            cls: cls,
            confidence: point.conf,
            bbox: CGRect(x: x, y: y, width: w, height: h)
        )
    }

    private func projectCenter(
        from center: CGPoint,
        velocity: CGVector,
        deltaTime: CFTimeInterval,
        maxSpeedPerSecond: CGFloat
    ) -> CGPoint {
        let cappedVelocity = clampVector(velocity, maxMagnitude: maxSpeedPerSecond)
        return CGPoint(
            x: center.x + (cappedVelocity.dx * CGFloat(deltaTime)),
            y: center.y + (cappedVelocity.dy * CGFloat(deltaTime))
        )
    }

    private func clampToFrame(_ point: CGPoint, frameW: CGFloat, frameH: CGFloat) -> CGPoint {
        CGPoint(
            x: clamp(point.x, lower: 0.0, upper: frameW),
            y: clamp(point.y, lower: 0.0, upper: frameH)
        )
    }

    private func clampVector(_ vector: CGVector, maxMagnitude: CGFloat) -> CGVector {
        guard maxMagnitude > 0 else { return .zero }
        let magnitude = hypot(vector.dx, vector.dy)
        guard magnitude > maxMagnitude, magnitude > 1e-6 else { return vector }
        let scale = maxMagnitude / magnitude
        return CGVector(dx: vector.dx * scale, dy: vector.dy * scale)
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + ((b - a) * t)
    }

    private func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }

    // MARK: - Detection window trimming

    private func trimDetectionWindow(now: CFTimeInterval) {
        let cutoff = now - windowMaxDuration
        if let firstIdxToKeep = detectionWindow.firstIndex(where: { $0.timestamp >= cutoff }) {
            if firstIdxToKeep > 0 { detectionWindow.removeFirst(firstIdxToKeep) }
        } else if !detectionWindow.isEmpty {
            detectionWindow.removeAll()
        }

        if detectionWindow.count > windowMaxFrames {
            detectionWindow.removeFirst(detectionWindow.count - windowMaxFrames)
        }
    }

    private func logShotEvent(_ event: DetectedShotEvent) {
        print("[ShotEvent] \(event.debugSummary)")
    }
}

public extension YOLODetection {
    func rectInView(size: CGSize) -> CGRect {
        let vx = bbox.origin.x
        let vy = bbox.origin.y
        let vw = bbox.size.width
        let vh = bbox.size.height
        let x = vx * size.width
        let yTopLeft = (1.0 - vy - vh) * size.height
        let w = vw * size.width
        let h = vh * size.height
        return CGRect(x: x, y: yTopLeft, width: w, height: h)
    }

    func centerInView(size: CGSize) -> CGPoint {
        let r = rectInView(size: size)
        return CGPoint(x: r.midX, y: r.midY)
    }
}
