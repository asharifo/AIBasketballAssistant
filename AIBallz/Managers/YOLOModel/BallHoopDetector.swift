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

    @Published private(set) var detectionWindow: [BestDetectionFrame] = []
    private let windowMaxDuration: CFTimeInterval = 5.0
    private let windowMaxFrames: Int = 90

    // Throttle Vision load
    private let throttleFPS: Double  = 15
    private var lastProcessTime: CFTimeInterval = 0

    // orientation
    private var cameraPosition: AVCaptureDevice.Position = .back
    func setCameraPosition(_ pos: AVCaptureDevice.Position) { cameraPosition = pos }

    private let visionQueue = DispatchQueue(label: "yolo.vision.queue", qos: .userInitiated)
    private let request: VNCoreMLRequest

    // -------------------------
    // MARK: - Python-style state
    // -------------------------

    private var frameCount: Int = 0

    /// Mirrors Python tuples: ((x,y), frame, w, h, conf) in PIXELS (OpenCV coords: origin top-left)
    private struct TrackPoint {
        var center: CGPoint   // pixel space, y increases downward
        var frame: Int
        var w: CGFloat        // pixel width
        var h: CGFloat        // pixel height
        var conf: Float
    }

    private var ballPos: [TrackPoint] = []
    private var hoopPos: [TrackPoint] = []

    // Used to detect shots (upper and lower region)
    private var up: Bool = false
    private var down: Bool = false
    private var upFrame: Int = 0
    private var downFrame: Int = 0

    // -------------------------
    // MARK: - Thresholds (match ShotDetector.py)
    // -------------------------

    // Python:
    // hoop if conf > .5
    private let hoopMinConf: Float = 0.50

    // Python:
    // ball if (conf > .3 OR (in_hoop_region and conf > .15))
    private let ballMinConf: Float = 0.30
    private let ballNearHoopMinConf: Float = 0.15

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

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: self.exifOrientationForCurrentDevice(),
            options: [:]
        )

        visionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try handler.perform([self.request])
                self.handleResults(frameW: CGFloat(width), frameH: CGFloat(height))
            } catch {
                DispatchQueue.main.async {
                    self.currentBestBall = nil
                    self.currentBestHoop = nil

                    let ts = CACurrentMediaTime()
                    self.detectionWindow.append(BestDetectionFrame(timestamp: ts, ball: nil, hoop: nil))
                    self.trimDetectionWindow(now: ts)

                    self.frameCount += 1
                }
            }
        }
    }

    // MARK: - Core per-frame loop with exact Python logic
    private func handleResults(frameW: CGFloat, frameH: CGFloat) {
        let ts = CACurrentMediaTime()
        let results = (request.results as? [VNRecognizedObjectObservation]) ?? []

        var candidatesBall: [YOLODetection] = []
        var candidatesHoop: [YOLODetection] = []

        for obs in results {
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

        // Best hoop with conf > .5
        let bestHoop = candidatesHoop
            .filter { $0.confidence > hoopMinConf }
            .max(by: { $0.confidence < $1.confidence })

        // If hoop passes threshold, append hoop point
        if let hoopDet = bestHoop {
            let hp = trackPointPixels(from: hoopDet, frameW: frameW, frameH: frameH, frame: frameCount)
            hoopPos.append(hp)
        }

        // Decide if each ball candidate should be accepted by Python rule
        // (conf > .3 OR (in_hoop_region and conf > .15))
        let acceptedBalls: [YOLODetection] = candidatesBall.filter { det in
            if det.confidence > ballMinConf { return true }

            if det.confidence > ballNearHoopMinConf {
                // in_hoop_region uses latest hoopPos AFTER any hoop append above
                let centerPix = centerPixels(fromVisionBBox: det.bbox, frameW: frameW, frameH: frameH)
                return inHoopRegion(center: centerPix)
            }
            return false
        }

        // Choose best accepted ball (max confidence)
        let bestBall = acceptedBalls.max(by: { $0.confidence < $1.confidence })

        if let ballDet = bestBall {
            let bp = trackPointPixels(from: ballDet, frameW: frameW, frameH: frameH, frame: frameCount)
            ballPos.append(bp)
        }

        // Clean motion exactly like utils.py
        cleanBallPos()
        cleanHoopPos()

        // Shot detection exactly like ShotDetector.py + utils.py
        shotDetection()

        DispatchQueue.main.async {
            self.currentBestBall = bestBall
            self.currentBestHoop = bestHoop

            self.detectionWindow.append(BestDetectionFrame(timestamp: ts, ball: bestBall, hoop: bestHoop))
            self.trimDetectionWindow(now: ts)
        }

        frameCount += 1
    }

    // MARK: - ShotDetector.shot_detection() + utils.py functions
    private func shotDetection() {
        guard !hoopPos.isEmpty, !ballPos.isEmpty else { return }

        // if not self.up: self.up = detect_up(...)
        if !up {
            up = detectUp()
            if up { upFrame = ballPos.last!.frame }
        }

        // if self.up and not self.down: self.down = detect_down(...)
        if up && !down {
            down = detectDown()
            if down { downFrame = ballPos.last!.frame }
        }

        // every 10 frames: if up && down && up_frame < down_frame: attempt++
        if frameCount % 10 == 0 {
            if up && down && upFrame < downFrame {
                shots += 1
                up = false
                down = false

                if scoreMake() {
                    makes += 1
                    lastShotResultText = "Make"
                } else {
                    lastShotResultText = "Miss"
                }
            }
        }
    }

    // utils.py: detect_up(ball_pos, hoop_pos)
    private func detectUp() -> Bool {
        guard let hoop = hoopPos.last, let ball = ballPos.last else { return false }

        let x1 = hoop.center.x - 4.0 * hoop.w
        let x2 = hoop.center.x + 4.0 * hoop.w
        let y1 = hoop.center.y - 2.0 * hoop.h
        let y2 = hoop.center.y

        // if x1 < ball.x < x2 and y1 < ball.y < y2 - 0.5*hoop.h
        return (x1 < ball.center.x && ball.center.x < x2) &&
               (y1 < ball.center.y && ball.center.y < (y2 - 0.5 * hoop.h))
    }

    // utils.py: detect_down(ball_pos, hoop_pos)
    private func detectDown() -> Bool {
        guard let hoop = hoopPos.last, let ball = ballPos.last else { return false }
        let y = hoop.center.y + 0.5 * hoop.h
        return ball.center.y > y
    }

    // utils.py: in_hoop_region(center, hoop_pos)
    private func inHoopRegion(center: CGPoint) -> Bool {
        guard let hoop = hoopPos.last else { return false }

        let x1 = hoop.center.x - 1.0 * hoop.w
        let x2 = hoop.center.x + 1.0 * hoop.w
        let y1 = hoop.center.y - 1.0 * hoop.h
        let y2 = hoop.center.y + 0.5 * hoop.h

        return (x1 < center.x && center.x < x2) &&
               (y1 < center.y && center.y < y2)
    }

    // utils.py: score(ball_pos, hoop_pos)
    private func scoreMake() -> Bool {
        guard let hoop = hoopPos.last else { return false }

        var xs: [CGFloat] = []
        var ys: [CGFloat] = []

        let rimHeight = hoop.center.y - 0.5 * hoop.h

        // find first point above rim (ball.y < rimHeight) in reverse
        if !ballPos.isEmpty {
            for i in stride(from: ballPos.count - 1, through: 0, by: -1) {
                if ballPos[i].center.y < rimHeight {
                    xs.append(ballPos[i].center.x)
                    ys.append(ballPos[i].center.y)

                    if i + 1 < ballPos.count {
                        xs.append(ballPos[i + 1].center.x)
                        ys.append(ballPos[i + 1].center.y)
                    }
                    break
                }
            }
        }

        // Create line from two points (polyfit degree 1 with 2 points)
        if xs.count > 1 {
            let x1 = xs[0], y1 = ys[0]
            let x2 = xs[1], y2 = ys[1]

            let dx = x2 - x1
            if abs(dx) < 1e-6 {
                // vertical-ish line: can't compute slope -> treat as no score
                return false
            }

            let m = (y2 - y1) / dx
            if abs(m) < 1e-6 {
                // nearly horizontal: predicted_x unstable
                return false
            }

            let b = y1 - m * x1

            let predictedX = (rimHeight - b) / m

            let rimX1 = hoop.center.x - 0.4 * hoop.w
            let rimX2 = hoop.center.x + 0.4 * hoop.w

            if rimX1 < predictedX && predictedX < rimX2 {
                return true
            }

            let hoopReboundZone: CGFloat = 10.0
            if (rimX1 - hoopReboundZone) < predictedX && predictedX < (rimX2 + hoopReboundZone) {
                return true
            }
        }

        return false
    }

    // utils.py: clean_ball_pos(ball_pos, frame_count)
    private func cleanBallPos() {
        if ballPos.count > 1 {
            let prev = ballPos[ballPos.count - 2]
            let cur  = ballPos[ballPos.count - 1]

            let w1 = prev.w, h1 = prev.h
            let w2 = cur.w,  h2 = cur.h

            let x1 = prev.center.x, y1 = prev.center.y
            let x2 = cur.center.x,  y2 = cur.center.y

            let fDif = cur.frame - prev.frame

            let dist = hypot(x2 - x1, y2 - y1)
            let maxDist = 4.0 * hypot(w1, h1)

            // if (dist > max_dist) and (f_dif < 5): pop
            if dist > maxDist && fDif < 5 {
                _ = ballPos.popLast()
            }
            // elif (w2*1.4 < h2) or (h2*1.4 < w2): pop
            else if (w2 * 1.4 < h2) || (h2 * 1.4 < w2) {
                _ = ballPos.popLast()
            }
        }

        // Remove points older than 30 frames
        if let first = ballPos.first {
            if frameCount - first.frame > 30 {
                ballPos.removeFirst()
            }
        }
    }

    // utils.py: clean_hoop_pos(hoop_pos)
    private func cleanHoopPos() {
        if hoopPos.count > 1 {
            let prev = hoopPos[hoopPos.count - 2]
            let cur  = hoopPos[hoopPos.count - 1]

            let x1 = prev.center.x, y1 = prev.center.y
            let x2 = cur.center.x,  y2 = cur.center.y

            let w1 = prev.w, h1 = prev.h
            let w2 = cur.w,  h2 = cur.h

            let fDif = cur.frame - prev.frame

            let dist = hypot(x2 - x1, y2 - y1)
            let maxDist = 0.5 * hypot(w1, h1)

            // if dist > max_dist and f_dif < 5: pop
            if dist > maxDist && fDif < 5 {
                _ = hoopPos.popLast()
            }

            // if (w2*1.3 < h2) or (h2*1.3 < w2): pop
            if hoopPos.count > 0 {
                // (re-check latest after possible pop above)
                let latest = hoopPos.last!
                if (latest.w * 1.3 < latest.h) || (latest.h * 1.3 < latest.w) {
                    _ = hoopPos.popLast()
                }
            }
        }

        // Remove old points if len > 25: pop(0)
        if hoopPos.count > 25 {
            hoopPos.removeFirst()
        }
    }

    // MARK: - Pixel conversion helpers (Vision bbox -> OpenCV-like pixel coords)

    private func trackPointPixels(from det: YOLODetection, frameW: CGFloat, frameH: CGFloat, frame: Int) -> TrackPoint {
        let center = centerPixels(fromVisionBBox: det.bbox, frameW: frameW, frameH: frameH)
        let size = sizePixels(fromVisionBBox: det.bbox, frameW: frameW, frameH: frameH)
        return TrackPoint(center: center, frame: frame, w: size.width, h: size.height, conf: det.confidence)
    }

    private func centerPixels(fromVisionBBox bbox: CGRect, frameW: CGFloat, frameH: CGFloat) -> CGPoint {
        // Vision bbox is normalized with origin lower-left.
        // Convert to pixel center with origin TOP-left (OpenCV-style):
        let cxN = bbox.midX
        let cyN = bbox.midY
        let cx = cxN * frameW
        let cy = (1.0 - cyN) * frameH
        return CGPoint(x: cx, y: cy)
    }

    private func sizePixels(fromVisionBBox bbox: CGRect, frameW: CGFloat, frameH: CGFloat) -> CGSize {
        return CGSize(width: bbox.width * frameW, height: bbox.height * frameH)
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
}

extension BallHoopDetector {
    private func exifOrientationForCurrentDevice() -> CGImagePropertyOrientation {
        func defaultOrientation() -> CGImagePropertyOrientation {
            return cameraPosition == .front ? .leftMirrored : .right
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

// MARK: - Existing UI helpers unchanged
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
