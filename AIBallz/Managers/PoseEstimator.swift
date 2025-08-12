import Foundation
import AVFoundation
import Vision
import CoreMedia
import UIKit


// sliding window
struct PoseFrame: Identifiable {
    let id = UUID()
    let timestamp: CFTimeInterval
    let bodyJoints: [PoseJoint: NormalizedPoint]
    let hands: [[PoseJoint: NormalizedPoint]]
}


final class PoseEstimator: ObservableObject {
    // keypoint location dictionaries
    @Published var bodyJoints: [PoseJoint: NormalizedPoint] = [:]
    @Published var hands: [[PoseJoint: NormalizedPoint]] = []   // up to 2 hands
    
    // sliding window of pose frames
    @Published private(set) var poseWindow: [PoseFrame] = []
    
    // sliding windows caps
    private let windowMaxDuration: CFTimeInterval = 2.0 // keep last 2 seconds
    private let windowMaxFrames: Int = 90               // keep last 90 frames


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
        // disregard frame if last run was too recent
        let now = CACurrentMediaTime()
        if now - lastProcessTime < (1.0 / throttleFPS) { return }
        lastProcessTime = now


        // extract CVPixelBuffer
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])


        visionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try handler.perform([self.bodyRequest, self.handRequest])

                // read body keypoints
                var bodyOut: [PoseJoint: NormalizedPoint] = [:]
                if let bodyObs = self.bodyRequest.results?.first as? VNHumanBodyPoseObservation {
                    let points = try bodyObs.recognizedPoints(.all)
                    for (vnName, p) in points where p.confidence > 0.2 {
                        if let j = mapVNBodyJoint(vnName) {
                            bodyOut[j] = CGPoint(x: CGFloat(p.location.x), y: CGFloat(p.location.y))
                        }
                    }
                }


                // read keypoints from each hand
                var handsOut: [[PoseJoint: NormalizedPoint]] = []
                if let handObs = self.handRequest.results as? [VNHumanHandPoseObservation] {
                    for obs in handObs {
                        let pts = try obs.recognizedPoints(.all)
                        var oneHand: [PoseJoint: NormalizedPoint] = [:]
                        for (vnName, p) in pts where p.confidence > 0.2 {
                            if let j = mapVNHandJoint(vnName) {
                                oneHand[j] = CGPoint(x: CGFloat(p.location.x), y: CGFloat(p.location.y))
                            }
                        }
                        if !oneHand.isEmpty { handsOut.append(oneHand) }
                    }
                }

                // assign keypoint locations on main queue
                DispatchQueue.main.async {
                    self.bodyJoints = bodyOut
                    self.hands = handsOut

                    // append to sliding window
                    let ts = CACurrentMediaTime()
                    let frame = PoseFrame(timestamp: ts, bodyJoints: bodyOut, hands: handsOut)
                    self.poseWindow.append(frame)
                    self.trimPoseWindow(now: ts)
                }
            } catch {
                DispatchQueue.main.async {
                    self.bodyJoints = [:]
                    self.hands = []
                    // keep sliding window in sync with BallHoopDetector
                    let ts = CACurrentMediaTime()
                    let frame = PoseFrame(timestamp: ts, bodyJoints: [:], hands: [])
                    self.poseWindow.append(frame)
                    self.trimPoseWindow(now: ts)
                }
            }
        }
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


    func currentPoseWindow() -> [PoseFrame] {
        return poseWindow
    }
}





