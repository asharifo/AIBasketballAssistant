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
    public let bbox: CGRect
}


// sliding-window container for detector frames
public struct DetectionFrame: Identifiable {
    public let id = UUID()
    public let timestamp: CFTimeInterval
    public let ball: YOLODetection?
    public let hoop: YOLODetection?
    public let allDetections: [YOLODetection]
}


final class BallHoopDetector: NSObject, ObservableObject {
    // ball and hoop detections
    @Published private(set) var balls: [YOLODetection] = []
    @Published private(set) var hoops: [YOLODetection] = []
    
    // shots and makes counters
    @Published private(set) var shots: Int = 0
    @Published private(set) var makes: Int = 0
    
    // sliding window config
    @Published private(set) var detectionWindow: [DetectionFrame] = []
    private let windowMaxDuration: CFTimeInterval = 2.0   // last 2s
    private let windowMaxFrames: Int = 90                 // last 90 frames
    
    private let minConfidence: Float = 0.5
    private let throttleFPS: Double  = 15
    private var lastProcessTime: CFTimeInterval = 0
    
    private let visionQueue = DispatchQueue(label: "yolo.vision.queue", qos: .userInitiated)
    private let request: VNCoreMLRequest


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
        // Throttle Vision load
        let now = CACurrentMediaTime()
        if now - lastProcessTime < (1.0 / throttleFPS) { return }
        lastProcessTime = now
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: Self.exifOrientationForCurrentDevice(),
            options: [:]
        )
        
        visionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try handler.perform([self.request])
                self.handleResults()
            } catch {
                DispatchQueue.main.async {
                    // clear live outputs
                    self.balls.removeAll()
                    self.hoops.removeAll()
                    
                    // append an empty frame into the sliding window to maintain continuity
                    let ts = CACurrentMediaTime()
                    self.detectionWindow.append(
                        DetectionFrame(timestamp: ts,
                                       ball: nil,
                                       hoop: nil,
                                       allDetections: [])
                    )
                    self.trimDetectionWindow(now: ts)
                }
            }
        }
    }
    
    private func handleResults() {
        guard let results = request.results as? [VNRecognizedObjectObservation] else {
            DispatchQueue.main.async {
                self.balls.removeAll()
                self.hoops.removeAll()
                
                // still keep window continuity with an empty frame
                let ts = CACurrentMediaTime()
                self.detectionWindow.append(
                    DetectionFrame(timestamp: ts,
                                   ball: nil,
                                   hoop: nil,
                                   allDetections: [])
                )
                self.trimDetectionWindow(now: ts)
            }
            return
        }
        
        var outBalls: [YOLODetection] = []
        var outHoops: [YOLODetection] = []
        
        for obs in results {
            guard let top = obs.labels.first, top.confidence >= minConfidence else { continue }
            let name = top.identifier
            let rect = obs.boundingBox        // normalized; your rectInView converts later
            let conf = top.confidence
            
            if name == TargetClass.basketball.rawValue {
                outBalls.append(YOLODetection(cls: .basketball, confidence: conf, bbox: rect))
            } else if name == TargetClass.hoop.rawValue {
                outHoops.append(YOLODetection(cls: .hoop, confidence: conf, bbox: rect))
            }
        }
        
        DispatchQueue.main.async {
            // publish latest per-frame arrays (existing behavior)
            self.balls = outBalls
            self.hoops = outHoops
            
            // compute best-by-confidence for convenience in window frames
            let bestBall = outBalls.max(by: { $0.confidence < $1.confidence })
            let bestHoop = outHoops.max(by: { $0.confidence < $1.confidence })
            
            // append to sliding window with timestamp
            let ts = CACurrentMediaTime()
            self.detectionWindow.append(
                DetectionFrame(timestamp: ts,
                               ball: bestBall,
                               hoop: bestHoop,
                               allDetections: outBalls + outHoops)
            )
            self.trimDetectionWindow(now: ts)
        }
    }
    
    private static func exifOrientationForCurrentDevice() -> CGImagePropertyOrientation {
        return .right
    }
    
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
    
    func currentDetectionWindow() -> [DetectionFrame] {
        return detectionWindow
    }
}

// for visualizing detections in ui
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
}





