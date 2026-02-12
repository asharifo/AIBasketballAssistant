import Foundation
import CoreML
import Vision
import AVFoundation
import CoreMedia
import UIKit

public enum TargetClass: String {
    case basketball = "Basketball"
    case hoop = "Basketball Hoop"
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

final class BallHoopDetector: NSObject, ObservableObject {

    @Published private(set) var currentBestBall: YOLODetection?
    @Published private(set) var currentBestHoop: YOLODetection?

    @Published private(set) var shots: Int = 0
    @Published private(set) var makes: Int = 0
    @Published private(set) var lastShotResultText: String = "Waiting..."
    @Published private(set) var overlayImageSize: CGSize = .zero

    @Published private(set) var detectionWindow: [BestDetectionFrame] = []
    private let windowMaxDuration: CFTimeInterval = 5.0
    private let windowMaxFrames: Int = 90

    // Throttle Vision load
    private let throttleFPS: Double = 15
    private var lastProcessTime: CFTimeInterval = 0

    // Orientation
    private var cameraPosition: AVCaptureDevice.Position = .back
    func setCameraPosition(_ pos: AVCaptureDevice.Position) { cameraPosition = pos }

    private let visionQueue = DispatchQueue(label: "yolo.vision.queue", qos: .userInitiated)
    private let request: VNCoreMLRequest

    private var frameCount: Int = 0

    /// Pixel space (origin top-left).
    private struct TrackPoint {
        var center: CGPoint
        var frame: Int
        var w: CGFloat
        var h: CGFloat
        var conf: Float
        var isPredicted: Bool
    }

    private struct TrackState {
        var latest: TrackPoint
        var velocity: CGVector // pixels per processed frame
        var missedFrames: Int
    }

    private struct TrackTuning {
        let occlusionToleranceFrames: Int
        let associationDistanceMultiplier: CGFloat
        let minAssociationDistance: CGFloat
        let maxSpeedPerFrame: CGFloat
        let measurementBlend: CGFloat
        let reacquireConfidence: Float
    }

    private struct TrackUpdate {
        let point: TrackPoint?
        let displayDetection: YOLODetection?
    }

    private enum ShotPhase {
        case idle
        case tracking(startFrame: Int)
        case cooldown(untilFrame: Int)
    }

    private enum ShotEvent {
        case make
        case miss
    }

    // Track histories (include predicted points to bridge short occlusions)
    private var ballPos: [TrackPoint] = []
    private var hoopPos: [TrackPoint] = []
    private var ballTrack: TrackState?
    private var hoopTrack: TrackState?

    private var shotPhase: ShotPhase = .idle
    private var sawBallAboveRimInAttempt = false
    private var rimCrossingX: CGFloat?
    private var rimCrossingFrame: Int?

    // Confidence thresholds
    private let hoopMinConf: Float = 0.50
    private let ballMinConf: Float = 0.30
    private let ballNearHoopMinConf: Float = 0.15

    // Tracking tuning
    private let ballTracking = TrackTuning(
        occlusionToleranceFrames: 12,
        associationDistanceMultiplier: 3.0,
        minAssociationDistance: 28.0,
        maxSpeedPerFrame: 110.0,
        measurementBlend: 0.78,
        reacquireConfidence: 0.60
    )

    private let hoopTracking = TrackTuning(
        occlusionToleranceFrames: 45,
        associationDistanceMultiplier: 1.8,
        minAssociationDistance: 22.0,
        maxSpeedPerFrame: 20.0,
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
    }

    func process(sampleBuffer: CMSampleBuffer) {
        let now = CACurrentMediaTime()
        if now - lastProcessTime < (1.0 / throttleFPS) { return }
        lastProcessTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let orientation = self.exifOrientationForCurrentDevice()
        let orientedImageSize = orientedImageSize(
            frameW: CGFloat(width),
            frameH: CGFloat(height),
            orientation: orientation
        )

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )

        visionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try handler.perform([self.request])
                let observations = (self.request.results as? [VNRecognizedObjectObservation]) ?? []
                self.handleResults(
                    observations,
                    frameW: CGFloat(width),
                    frameH: CGFloat(height),
                    overlayImageSize: orientedImageSize
                )
            } catch {
                // Keep track continuity on occasional request failures.
                self.handleResults(
                    [],
                    frameW: CGFloat(width),
                    frameH: CGFloat(height),
                    overlayImageSize: orientedImageSize
                )
            }
        }
    }

    private func handleResults(
        _ observations: [VNRecognizedObjectObservation],
        frameW: CGFloat,
        frameH: CGFloat,
        overlayImageSize: CGSize
    ) {
        let timestamp = CACurrentMediaTime()

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
            frame: frameCount
        )
        if let point = hoopUpdate.point { hoopPos.append(point) }
        cleanHoopPos()

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
            frame: frameCount
        )
        if let point = ballUpdate.point { ballPos.append(point) }
        cleanBallPos()

        let shotEvent = shotDetection()
        frameCount += 1

        let publishBall = ballUpdate.displayDetection
        let publishHoop = hoopUpdate.displayDetection

        DispatchQueue.main.async {
            self.currentBestBall = publishBall
            self.currentBestHoop = publishHoop
            self.overlayImageSize = overlayImageSize

            if let shotEvent {
                self.shots += 1
                switch shotEvent {
                case .make:
                    self.makes += 1
                    self.lastShotResultText = "Make"
                case .miss:
                    self.lastShotResultText = "Miss"
                }
            }

            self.detectionWindow.append(
                BestDetectionFrame(timestamp: timestamp, ball: publishBall, hoop: publishHoop)
            )
            self.trimDetectionWindow(now: timestamp)
        }
    }

    // MARK: - Shot logic

    private func shotDetection() -> ShotEvent? {
        guard let hoop = hoopPos.last, let ball = ballPos.last else {
            if case .tracking(let startFrame) = shotPhase, frameCount - startFrame > 60 {
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
            // Arm only if ball is near hoop and moving up.
            if nearHoopX &&
                velocityY < -1.5 &&
                ball.center.y < hoop.center.y + (2.5 * hoop.h) {
                shotPhase = .tracking(startFrame: frameCount)
                sawBallAboveRimInAttempt = ball.center.y < rimY - (0.2 * hoop.h)
                rimCrossingX = nil
                rimCrossingFrame = nil
            }

        case .tracking(let startFrame):
            sawBallAboveRimInAttempt = sawBallAboveRimInAttempt || (ball.center.y < rimY - (0.2 * hoop.h))

            if rimCrossingFrame == nil,
               sawBallAboveRimInAttempt,
               let crossingX = downwardRimCrossingX(rimY: rimY) {
                rimCrossingFrame = frameCount
                rimCrossingX = crossingX
            }

            if let crossingFrame = rimCrossingFrame, let crossingX = rimCrossingX {
                let settledBelowRim = ball.center.y > hoop.center.y + (0.85 * hoop.h)
                let crossingTimedOut = frameCount - crossingFrame > 14

                if settledBelowRim || crossingTimedOut {
                    let innerHalfWidth = max(8.0, 0.42 * hoop.w)
                    let outerHalfWidth = max(12.0, 0.68 * hoop.w)

                    let centeredAtRim = abs(crossingX - hoop.center.x) <= innerHalfWidth
                    let stayedNearCenterBelow = abs(ball.center.x - hoop.center.x) <= outerHalfWidth
                    return finalizeAttempt(make: centeredAtRim && stayedNearCenterBelow)
                }
            } else {
                let attemptTimedOut = frameCount - startFrame > 55
                let descendingPastHoop = sawBallAboveRimInAttempt &&
                    velocityY > 1.5 &&
                    ball.center.y > hoop.center.y + (0.4 * hoop.h)
                let escapedSideways = distanceX > max(80.0, 4.2 * hoop.w) && velocityY > 0.8

                if attemptTimedOut || descendingPastHoop || escapedSideways {
                    if sawBallAboveRimInAttempt {
                        return finalizeAttempt(make: false)
                    }
                    resetAttemptState()
                    shotPhase = .idle
                }
            }

        case .cooldown(let untilFrame):
            if frameCount >= untilFrame {
                shotPhase = .idle
            }
        }

        return nil
    }

    private func finalizeAttempt(make: Bool) -> ShotEvent {
        resetAttemptState()
        shotPhase = .cooldown(untilFrame: frameCount + 12)
        return make ? .make : .miss
    }

    private func resetAttemptState() {
        sawBallAboveRimInAttempt = false
        rimCrossingX = nil
        rimCrossingFrame = nil
    }

    private func currentBallVelocityY() -> CGFloat? {
        guard ballPos.count > 1 else { return nil }
        let previous = ballPos[ballPos.count - 2]
        let current = ballPos[ballPos.count - 1]
        let frameDelta = max(1, current.frame - previous.frame)
        return (current.center.y - previous.center.y) / CGFloat(frameDelta)
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
        frame: Int
    ) -> TrackUpdate {
        let measurementPoint = measurement.map {
            trackPointPixels(from: $0, frameW: frameW, frameH: frameH, frame: frame, predicted: false)
        }

        if var existing = track {
            let frameDelta = max(1, frame - existing.latest.frame)
            let predictedCenter = projectCenter(
                from: existing.latest.center,
                velocity: existing.velocity,
                frameDelta: frameDelta,
                maxSpeedPerFrame: tuning.maxSpeedPerFrame
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
                let shouldAssociate = distanceToPrediction <= associationRadius ||
                    measurement.confidence >= tuning.reacquireConfidence

                if shouldAssociate {
                    let blendedCenter = CGPoint(
                        x: lerp(predictedCenter.x, measurementPoint.center.x, tuning.measurementBlend),
                        y: lerp(predictedCenter.y, measurementPoint.center.y, tuning.measurementBlend)
                    )
                    let blendedPoint = TrackPoint(
                        center: clampToFrame(blendedCenter, frameW: frameW, frameH: frameH),
                        frame: frame,
                        w: lerp(existing.latest.w, measurementPoint.w, 0.35),
                        h: lerp(existing.latest.h, measurementPoint.h, 0.35),
                        conf: measurement.confidence,
                        isPredicted: false
                    )

                    let rawVelocity = CGVector(
                        dx: (blendedPoint.center.x - existing.latest.center.x) / CGFloat(frameDelta),
                        dy: (blendedPoint.center.y - existing.latest.center.y) / CGFloat(frameDelta)
                    )
                    let cappedVelocity = clampVector(rawVelocity, maxMagnitude: tuning.maxSpeedPerFrame)
                    existing.velocity = CGVector(
                        dx: (existing.velocity.dx * 0.55) + (cappedVelocity.dx * 0.45),
                        dy: (existing.velocity.dy * 0.55) + (cappedVelocity.dy * 0.45)
                    )
                    existing.latest = blendedPoint
                    existing.missedFrames = 0
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

            if existing.missedFrames < tuning.occlusionToleranceFrames {
                let predictedVelocity = clampVector(existing.velocity, maxMagnitude: tuning.maxSpeedPerFrame)
                let predictedCenter = clampToFrame(
                    CGPoint(
                        x: existing.latest.center.x + predictedVelocity.dx,
                        y: existing.latest.center.y + predictedVelocity.dy
                    ),
                    frameW: frameW,
                    frameH: frameH
                )

                let predictedPoint = TrackPoint(
                    center: predictedCenter,
                    frame: frame,
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
                existing.missedFrames += 1
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
                missedFrames: 0
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

    private func cleanBallPos() {
        if ballPos.count > 1 {
            let previous = ballPos[ballPos.count - 2]
            let current = ballPos[ballPos.count - 1]
            let frameDelta = max(1, current.frame - previous.frame)

            if !current.isPredicted {
                let distance = hypot(current.center.x - previous.center.x, current.center.y - previous.center.y)
                let maxDistance = max(30.0, 5.0 * max(previous.w, previous.h)) * CGFloat(frameDelta)
                if distance > maxDistance {
                    _ = ballPos.popLast()
                    if var track = ballTrack {
                        track.latest = previous
                        track.velocity = .zero
                        track.missedFrames = 0
                        ballTrack = track
                    }
                }
            }
        }

        trimHistory(&ballPos, maxAgeFrames: 90)
    }

    private func cleanHoopPos() {
        if hoopPos.count > 1 {
            let previous = hoopPos[hoopPos.count - 2]
            let current = hoopPos[hoopPos.count - 1]
            let frameDelta = max(1, current.frame - previous.frame)

            if !current.isPredicted {
                let distance = hypot(current.center.x - previous.center.x, current.center.y - previous.center.y)
                let maxDistance = max(20.0, 1.8 * max(previous.w, previous.h)) * CGFloat(frameDelta)
                if distance > maxDistance {
                    _ = hoopPos.popLast()
                    if var track = hoopTrack {
                        track.latest = previous
                        track.velocity = .zero
                        track.missedFrames = 0
                        hoopTrack = track
                    }
                }
            }
        }

        trimHistory(&hoopPos, maxAgeFrames: 180)
    }

    private func trimHistory(_ history: inout [TrackPoint], maxAgeFrames: Int) {
        let cutoff = frameCount - maxAgeFrames
        if let firstToKeep = history.firstIndex(where: { $0.frame >= cutoff }) {
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

        return (x1 < center.x && center.x < x2) &&
               (y1 < center.y && center.y < y2)
    }

    // MARK: - Pixel conversion helpers (Vision bbox -> OpenCV-like pixel coords)

    private func trackPointPixels(
        from det: YOLODetection,
        frameW: CGFloat,
        frameH: CGFloat,
        frame: Int,
        predicted: Bool
    ) -> TrackPoint {
        let center = centerPixels(fromVisionBBox: det.bbox, frameW: frameW, frameH: frameH)
        let size = sizePixels(fromVisionBBox: det.bbox, frameW: frameW, frameH: frameH)
        return TrackPoint(
            center: center,
            frame: frame,
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

        // Clamp to normalized bounds.
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
        frameDelta: Int,
        maxSpeedPerFrame: CGFloat
    ) -> CGPoint {
        let cappedVelocity = clampVector(velocity, maxMagnitude: maxSpeedPerFrame)
        return CGPoint(
            x: center.x + (cappedVelocity.dx * CGFloat(frameDelta)),
            y: center.y + (cappedVelocity.dy * CGFloat(frameDelta))
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

    func currentDetectionWindow() -> [BestDetectionFrame] { detectionWindow }

    func restoreCounters(shots: Int, makes: Int) {
        DispatchQueue.main.async {
            self.shots = max(0, shots)
            self.makes = max(0, min(makes, shots))
            self.lastShotResultText = "Waiting..."
        }
    }
}

extension BallHoopDetector {
    private func orientedImageSize(
        frameW: CGFloat,
        frameH: CGFloat,
        orientation: CGImagePropertyOrientation
    ) -> CGSize {
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored:
            return CGSize(width: frameH, height: frameW)
        default:
            return CGSize(width: frameW, height: frameH)
        }
    }

    private func exifOrientationForCurrentDevice() -> CGImagePropertyOrientation {
        func defaultOrientation() -> CGImagePropertyOrientation {
            cameraPosition == .front ? .leftMirrored : .right
        }

        switch UIDevice.current.orientation {
        case .portrait:
            return cameraPosition == .front ? .leftMirrored : .right
        case .portraitUpsideDown:
            return cameraPosition == .front ? .rightMirrored : .left
        case .landscapeLeft:
            return cameraPosition == .front ? .downMirrored : .up
        case .landscapeRight:
            return cameraPosition == .front ? .upMirrored : .down
        default:
            return defaultOrientation()
        }
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
