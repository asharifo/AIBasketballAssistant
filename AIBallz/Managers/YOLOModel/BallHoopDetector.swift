
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

/// One detection result in normalized image space (0..1), origin bottom-left.
public struct YOLODetection: Identifiable {
    public let id = UUID()
    public let cls: TargetClass
    public let confidence: Float
    public let bbox: CGRect
}


final class BallHoopDetector: NSObject, ObservableObject {

    // MARK: - Outputs you can observe
    @Published private(set) var balls: [YOLODetection] = []
    @Published private(set) var hoops: [YOLODetection] = []


    // MARK: - Config
    private let minConfidence: Float = 0.3
    private let throttleFPS: Double = 15


    // MARK: - Internals
    private var lastProcessTime: CFTimeInterval = 0
    private let visionQueue = DispatchQueue(label: "yolo.vision.queue", qos: .userInitiated)
    private let request: VNCoreMLRequest


    // MARK: - Init
    override init() {
        // Try generated Swift interface first (easiest).
        // If your generated class isn't `Best`, replace `Best` below with your actual class name.
        let coreMLModel: MLModel
        if let modelFromClass = BallHoopDetector.loadGeneratedClassModel() {
            coreMLModel = modelFromClass
        } else if let modelFromBundle = BallHoopDetector.loadCompiledModelFromBundle(named: "best") {
            coreMLModel = modelFromBundle
        } else {
            fatalError("""
            Could not load Core ML model.
            - Ensure `best.mlpackage` is added to the app target (Copy items if needed).
            - Or rename `loadCompiledModelFromBundle(named:)` to the compiled name.
            """)
        }


        guard let vnModel = try? VNCoreMLModel(for: coreMLModel) else {
            fatalError("Failed to wrap MLModel in VNCoreMLModel.")
        }


        // Configure the Vision request
        let req = VNCoreMLRequest(model: vnModel)
        req.imageCropAndScaleOption = .scaleFill
        self.request = req
        super.init()
    }


    // MARK: - Public API

    func process(sampleBuffer: CMSampleBuffer) {
        // Throttle
        let now = CACurrentMediaTime()
        if now - lastProcessTime < (1.0 / throttleFPS) { return }
        lastProcessTime = now


        // Extract pixel buffer
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }


        // Infer orientation (portrait camera in your setup)
        let orientation = BallHoopDetector.exifOrientationForCurrentDevice()


        // Build handler & perform off-main
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: orientation,
                                            options: [:])
        visionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try handler.perform([self.request])
                self.handleResults()
            } catch {
                DispatchQueue.main.async {
                    self.balls.removeAll()
                    self.hoops.removeAll()
                }
            }
        }
    }


    // MARK: - Results handling


    private func handleResults() {
        guard let results = request.results as? [VNRecognizedObjectObservation] else {
            DispatchQueue.main.async {
                self.balls.removeAll()
                self.hoops.removeAll()
            }
            return
        }


        var outBalls: [YOLODetection] = []
        var outHoops: [YOLODetection] = []


        for obs in results {
            // The top label is usually the predicted class
            guard let top = obs.labels.first, top.confidence >= minConfidence else { continue }
            let name = top.identifier


            // Vision gives bbox in normalized coords (origin bottom-left)
            let rect = obs.boundingBox
            let conf = top.confidence


            if name == TargetClass.basketball.rawValue {
                outBalls.append(YOLODetection(cls: .basketball, confidence: conf, bbox: rect))
            } else if name == TargetClass.hoop.rawValue {
                outHoops.append(YOLODetection(cls: .hoop, confidence: conf, bbox: rect))
            }
        }


        DispatchQueue.main.async {
            self.balls = outBalls
            self.hoops = outHoops
        }
    }


    // MARK: - Helpers: Model loading

    private static func loadGeneratedClassModel() -> MLModel? {
        // Replace `Best` with your actual generated class name if different.
        // If the class doesn't exist, this block will compile but fail at runtime,
        // so we do a reflective approach: attempt to create via Best(configuration:).
        #if canImport(CoreML)
        do {
            // Attempt to reference the symbol dynamically.
            // If your class name isn't `Best`, update it here.
            if let BestType = NSClassFromString(Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "" + ".Best") as? NSObject.Type {
                let obj = BestType.init()
                // Try to read `model` KVC — generated classes expose a `model` property.
                if let m = obj.value(forKey: "model") as? MLModel {
                    return m
                }
            }
        } catch {
            // ignore and fall back
        }
        // Direct approach if you know the name: uncomment & set correct class
        // do { return try Best(configuration: MLModelConfiguration()).model } catch { }
        #endif
        return nil
    }


    /// Load compiled `.mlmodelc` by resource name (compiled from your `.mlpackage`).
    private static func loadCompiledModelFromBundle(named baseName: String) -> MLModel? {
        guard let url = Bundle.main.url(forResource: baseName, withExtension: "mlmodelc") else {
            return nil
        }
        return try? MLModel(contentsOf: url)
    }


    // MARK: - Helpers: Orientation


    /// Map device orientation to EXIF orientation used by Vision.
    private static func exifOrientationForCurrentDevice() -> CGImagePropertyOrientation {
        // For your app you're fixing capture to portrait;
        // if you later support rotation, inspect UIDevice.current.orientation here.
        return .right // portrait camera frames
    }
}


// MARK: - Coordinate utilities (optional)


public extension YOLODetection {
    /// Convert the Vision normalized rect (origin bottom-left) into a CGRect in a given view size (UIKit coordinates, origin top-left).
    func rectInView(size: CGSize) -> CGRect {
        // Vision bbox: (x, y, w, h) normalized, origin bottom-left.
        let vx = bbox.origin.x
        let vy = bbox.origin.y
        let vw = bbox.size.width
        let vh = bbox.size.height


        // Convert to pixel space with origin top-left (UIKit)
        let x = vx * size.width
        let yTopLeft = (1.0 - vy - vh) * size.height
        let w = vw * size.width
        let h = vh * size.height
        return CGRect(x: x, y: yTopLeft, width: w, height: h)
    }
}





