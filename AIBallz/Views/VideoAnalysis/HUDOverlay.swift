import SwiftUI

struct HUDOverlay: View {
    @ObservedObject var detector: BallHoopDetector
    @ObservedObject var pose: PoseEstimator

    private var message: String? {
        let noBall = detector.currentBestBall == nil
        let noHoop = detector.currentBestHoop == nil

        if noBall && noHoop { return "Ball and hoop not detected" }
        if noBall { return "Ball not detected" }
        if noHoop { return "Hoop not detected" }
        return nil
    }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                let viewSize = proxy.size
                let imageSize = normalizedImageSize(for: viewSize)

                ZStack {
                    if let ball = detector.currentBestBall {
                        Circle()
                            .fill(Color.orange.opacity(0.95))
                            .frame(width: 10, height: 10)
                            .position(convertDetectionCenter(ball, in: viewSize, imageSize: imageSize))
                            .shadow(radius: 2)
                    }

                    if let hoop = detector.currentBestHoop {
                        Circle()
                            .strokeBorder(Color.green.opacity(0.95), lineWidth: 2)
                            .frame(width: 14, height: 14)
                            .position(convertDetectionCenter(hoop, in: viewSize, imageSize: imageSize))
                            .shadow(radius: 2)
                    }

                    ForEach(Array(pose.bodyJoints.keys), id: \.self) { joint in
                        if let p = pose.bodyJoints[joint] {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 8, height: 8)
                                .position(convertVisionNormalizedPoint(p, in: viewSize, imageSize: imageSize))
                                .shadow(radius: 1)
                        }
                    }

                    ForEach(0..<pose.hands.count, id: \.self) { handIndex in
                        let hand = pose.hands[handIndex]
                        ForEach(Array(hand.keys), id: \.self) { joint in
                            if let p = hand[joint] {
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 6, height: 6)
                                    .position(convertVisionNormalizedPoint(p, in: viewSize, imageSize: imageSize))
                            }
                        }
                    }
                }
                .allowsHitTesting(false)
            }

            VStack {
                if let message {
                    Text(message)
                        .font(.callout)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .shadow(radius: 2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .padding(.top, 8)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            VStack(alignment: .leading, spacing: 4) {
                Text("Shots: \(detector.shots)")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                Text("Makes: \(detector.makes)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 52)
            .padding(.leading, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .animation(.easeInOut(duration: 0.2), value: message)
        .allowsHitTesting(false)
    }

    private func normalizedImageSize(for viewSize: CGSize) -> CGSize {
        let detected = detector.overlayImageSize
        if detected.width > 0, detected.height > 0 { return detected }
        return CGSize(width: max(1, viewSize.width), height: max(1, viewSize.height))
    }

    private func convertDetectionCenter(
        _ detection: YOLODetection,
        in viewSize: CGSize,
        imageSize: CGSize
    ) -> CGPoint {
        let normalizedTopLeft = CGPoint(
            x: detection.bbox.midX,
            y: 1.0 - detection.bbox.midY
        )
        return mapNormalizedTopLeftPoint(normalizedTopLeft, in: viewSize, imageSize: imageSize)
    }

    private func convertVisionNormalizedPoint(
        _ point: CGPoint,
        in viewSize: CGSize,
        imageSize: CGSize
    ) -> CGPoint {
        let normalizedTopLeft = CGPoint(x: point.x, y: 1.0 - point.y)
        return mapNormalizedTopLeftPoint(normalizedTopLeft, in: viewSize, imageSize: imageSize)
    }

    private func mapNormalizedTopLeftPoint(
        _ normalizedTopLeft: CGPoint,
        in viewSize: CGSize,
        imageSize: CGSize
    ) -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return .zero
        }

        let clampedX = min(max(normalizedTopLeft.x, 0), 1)
        let clampedY = min(max(normalizedTopLeft.y, 0), 1)

        // Matches AVCaptureVideoPreviewLayer with .resizeAspectFill.
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let displayedWidth = imageSize.width * scale
        let displayedHeight = imageSize.height * scale
        let xOffset = (viewSize.width - displayedWidth) / 2
        let yOffset = (viewSize.height - displayedHeight) / 2

        return CGPoint(
            x: xOffset + (clampedX * displayedWidth),
            y: yOffset + (clampedY * displayedHeight)
        )
    }
}
