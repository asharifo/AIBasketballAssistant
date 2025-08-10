import Foundation
import AVFoundation
import Vision
import CoreMedia
import UIKit

final class PoseEstimator: ObservableObject {
    @Published var bodyJoints: [PoseJoint: NormalizedPoint] = [:]
    @Published var hands: [[PoseJoint: NormalizedPoint]] = []   // up to 2 hands

    private let bodyRequest = VNDetectHumanBodyPoseRequest()
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()

    private let visionQueue = DispatchQueue(label: "pose.vision.queue")
    private var lastProcessTime: CFTimeInterval = 0
    private let throttleFPS: Double = 15

    func process(sampleBuffer: CMSampleBuffer) {
        // throttle Vision load
        let now = CACurrentMediaTime()
        if now - lastProcessTime < (1.0 / throttleFPS) { return }
        lastProcessTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        visionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try handler.perform([self.bodyRequest, self.handRequest])

                // BODY
                var bodyOut: [PoseJoint: NormalizedPoint] = [:]
                if let bodyObs = self.bodyRequest.results?.first as? VNHumanBodyPoseObservation {
                    let points = try bodyObs.recognizedPoints(.all)
                    for (vnName, p) in points where p.confidence > 0.2 {
                        if let j = mapVNBodyJoint(vnName) {
                            bodyOut[j] = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
                        }
                    }
                }

                // HANDS (per observation)
                var handsOut: [[PoseJoint: NormalizedPoint]] = []
                if let handObs = self.handRequest.results as? [VNHumanHandPoseObservation] {
                    for obs in handObs {
                        let pts = try obs.recognizedPoints(.all)
                        var oneHand: [PoseJoint: NormalizedPoint] = [:]
                        for (vnName, p) in pts where p.confidence > 0.2 {
                            if let j = mapVNHandJoint(vnName) {
                                oneHand[j] = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
                            }
                        }
                        if !oneHand.isEmpty { handsOut.append(oneHand) }
                    }
                }

                DispatchQueue.main.async {
                    self.bodyJoints = bodyOut
                    self.hands = handsOut
                }
            } catch {
                DispatchQueue.main.async {
                    self.bodyJoints = [:]
                    self.hands = []
                }
            }
        }
    }
}



