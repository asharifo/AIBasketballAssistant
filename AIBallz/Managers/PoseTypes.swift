import CoreGraphics
import Vision

public typealias NormalizedPoint = CGPoint

public enum PoseJoint: String, CaseIterable {
    // Body
    case nose, neck
    case leftShoulder, leftElbow, leftWrist
    case rightShoulder, rightElbow, rightWrist
    case leftHip, leftKnee, leftAnkle
    case rightHip, rightKnee, rightAnkle

    // Minimal hand (applies to each detected hand; Vision does not tag left/right)
    case wrist
    case thumbTip, indexTip, middleTip, ringTip, littleTip
}

// Map Vision body joint -> unified PoseJoint
func mapVNBodyJoint(_ name: VNHumanBodyPoseObservation.JointName) -> PoseJoint? {
    switch name {
    case .nose: return .nose
    case .neck: return .neck
    case .leftShoulder: return .leftShoulder
    case .leftElbow: return .leftElbow
    case .leftWrist: return .leftWrist
    case .rightShoulder: return .rightShoulder
    case .rightElbow: return .rightElbow
    case .rightWrist: return .rightWrist
    case .leftHip: return .leftHip
    case .leftKnee: return .leftKnee
    case .leftAnkle: return .leftAnkle
    case .rightHip: return .rightHip
    case .rightKnee: return .rightKnee
    case .rightAnkle: return .rightAnkle
    default: return nil
    }
}

// Map Vision hand joint -> unified PoseJoint (minimal)
func mapVNHandJoint(_ name: VNHumanHandPoseObservation.JointName) -> PoseJoint? {
    switch name {
    case .wrist: return .wrist
    case .thumbTip: return .thumbTip
    case .indexTip: return .indexTip
    case .middleTip: return .middleTip
    case .ringTip: return .ringTip
    case .littleTip: return .littleTip
    default: return nil
    }
}



