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


// history container for per-frame best detections
public struct BestDetectionFrame: Identifiable {
    public let id = UUID()
    public let timestamp: CFTimeInterval
    public let ball: YOLODetection?
    public let hoop: YOLODetection?
}


final class BallHoopDetector: NSObject, ObservableObject {
    // Best detections for the CURRENT frame (for HUD overlay, etc.)
    @Published private(set) var currentBestBall: YOLODetection?
    @Published private(set) var currentBestHoop: YOLODetection?
    
    // shots and makes counters
    @Published private(set) var shots: Int = 0
    @Published private(set) var makes: Int = 0
    
    
    // sliding window config
    @Published private(set) var detectionWindow: [BestDetectionFrame] = []
    private let windowMaxDuration: CFTimeInterval = 5.0   // last 5s
    private let windowMaxFrames: Int = 90                 // last 90 frames
    
    
    private let minConfidence: Float = 0.5
    private let throttleFPS: Double  = 15
    private var lastProcessTime: CFTimeInterval = 0
    
    // orientation
    private var cameraPosition: AVCaptureDevice.Position = .back
    func setCameraPosition(_ pos: AVCaptureDevice.Position) { cameraPosition = pos }
    
    
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
            orientation: self.exifOrientationForCurrentDevice(),
            options: [:]
        )
        
        
        visionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try handler.perform([self.request])
                self.handleResults()
            } catch {
                DispatchQueue.main.async {
                    // clear live outputs for this frame
                    self.currentBestBall = nil
                    self.currentBestHoop = nil
                    
                    // append empty bests to history to keep continuity
                    let ts = CACurrentMediaTime()
                    self.detectionWindow.append(
                        BestDetectionFrame(timestamp: ts, ball: nil, hoop: nil)
                    )
                    self.trimDetectionWindow(now: ts)
                }
            }
        }
    }
    
    
    private func handleResults() {
        guard let results = request.results as? [VNRecognizedObjectObservation] else {
            DispatchQueue.main.async {
                self.currentBestBall = nil
                self.currentBestHoop = nil
                
                let ts = CACurrentMediaTime()
                self.detectionWindow.append(
                    BestDetectionFrame(timestamp: ts, ball: nil, hoop: nil)
                )
                self.trimDetectionWindow(now: ts)
            }
            return
        }
        
        
        var candidatesBall: [YOLODetection] = []
        var candidatesHoop: [YOLODetection] = []
        
        
        for obs in results {
            guard let top = obs.labels.first, top.confidence >= minConfidence else { continue }
            let name = top.identifier
            let rect = obs.boundingBox
            let conf = top.confidence
            
            
            if name == TargetClass.basketball.rawValue {
                candidatesBall.append(YOLODetection(cls: .basketball, confidence: conf, bbox: rect))
            } else if name == TargetClass.hoop.rawValue {
                candidatesHoop.append(YOLODetection(cls: .hoop, confidence: conf, bbox: rect))
            }
        }
        
        
        // choose max-confidence per class
        let bestBall = candidatesBall.max(by: { $0.confidence < $1.confidence })
        let bestHoop = candidatesHoop.max(by: { $0.confidence < $1.confidence })
        
        
        DispatchQueue.main.async {
            let ts = CACurrentMediaTime()
            
            // publish only the best for the current frame
            self.currentBestBall = bestBall
            self.currentBestHoop = bestHoop
            
            
            // append bests to history
            self.detectionWindow.append(
                BestDetectionFrame(timestamp: ts, ball: bestBall, hoop: bestHoop)
            )
            self.trimDetectionWindow(now: ts)
        }
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
    
    func currentDetectionWindow() -> [BestDetectionFrame] {
        return detectionWindow
    }
}

extension BallHoopDetector {
    /// Compute the EXIF orientation Vision expects, based on the current device orientation and which camera is active.
    private func exifOrientationForCurrentDevice() -> CGImagePropertyOrientation {
        // Fallback when orientation is unknown/faceUp/faceDown
        func defaultOrientation() -> CGImagePropertyOrientation {
            return cameraPosition == .front ? .leftMirrored : .right
        }
        
        switch UIDevice.current.orientation {
        case .portrait:
            return cameraPosition == .front ? .leftMirrored : .right
        case .portraitUpsideDown:
            return cameraPosition == .front ? .rightMirrored : .left
        case .landscapeLeft:
            // Home button on the right (old iPhones) – device rotated left
            return cameraPosition == .front ? .downMirrored : .up
        case .landscapeRight:
            // Home button on the left – device rotated right
            return cameraPosition == .front ? .upMirrored : .down
        default:
            return defaultOrientation()
        }
    }
}


// for visualizing detections in UI
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





