import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import QuartzCore
import UIKit

struct AnalysisFrame {
    let pixelBuffer: CVPixelBuffer
    let timestamp: CFTimeInterval
    let orientation: CGImagePropertyOrientation
    let orientedImageSize: CGSize
}

enum AnalysisFrameGeometry {
    static func liveFrame(
        from sampleBuffer: CMSampleBuffer,
        cameraPosition: AVCaptureDevice.Position
    ) -> AnalysisFrame? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

        let orientation = deviceExifOrientation(
            deviceOrientation: UIDevice.current.orientation,
            cameraPosition: cameraPosition
        )
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampSeconds = CMTimeGetSeconds(presentationTime)
        let timestamp = timestampSeconds.isFinite ? timestampSeconds : CACurrentMediaTime()

        return AnalysisFrame(
            pixelBuffer: pixelBuffer,
            timestamp: timestamp,
            orientation: orientation,
            orientedImageSize: orientedImageSize(frameW: width, frameH: height, orientation: orientation)
        )
    }

    static func fileFrame(
        pixelBuffer: CVPixelBuffer,
        timestamp: CFTimeInterval,
        orientation: CGImagePropertyOrientation
    ) -> AnalysisFrame {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        return AnalysisFrame(
            pixelBuffer: pixelBuffer,
            timestamp: timestamp,
            orientation: orientation,
            orientedImageSize: orientedImageSize(frameW: width, frameH: height, orientation: orientation)
        )
    }

    static func orientedImageSize(
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

    static func deviceExifOrientation(
        deviceOrientation: UIDeviceOrientation,
        cameraPosition: AVCaptureDevice.Position
    ) -> CGImagePropertyOrientation {
        func defaultOrientation() -> CGImagePropertyOrientation {
            cameraPosition == .front ? .leftMirrored : .right
        }

        switch deviceOrientation {
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

    static func videoExifOrientation(from preferredTransform: CGAffineTransform) -> CGImagePropertyOrientation {
        // Common transforms from AVAssetTrack.preferredTransform.
        if preferredTransform.a == 0,
           preferredTransform.b == 1,
           preferredTransform.c == -1,
           preferredTransform.d == 0 {
            return .right
        }

        if preferredTransform.a == 0,
           preferredTransform.b == -1,
           preferredTransform.c == 1,
           preferredTransform.d == 0 {
            return .left
        }

        if preferredTransform.a == 1,
           preferredTransform.b == 0,
           preferredTransform.c == 0,
           preferredTransform.d == 1 {
            return .up
        }

        if preferredTransform.a == -1,
           preferredTransform.b == 0,
           preferredTransform.c == 0,
           preferredTransform.d == -1 {
            return .down
        }

        return .right
    }
}
