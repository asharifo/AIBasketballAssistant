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
            // detection dots + pose keypoints
            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    if let ball = detector.currentBestBall {
                        Circle()
                            .fill(Color.orange.opacity(0.95))
                            .frame(width: 10, height: 10)
                            .position(ball.centerInView(size: size))
                            .shadow(radius: 2)
                    }
                    if let hoop = detector.currentBestHoop {
                        Circle()
                            .strokeBorder(Color.green.opacity(0.95), lineWidth: 2)
                            .frame(width: 14, height: 14)
                            .position(hoop.centerInView(size: size))
                            .shadow(radius: 2)
                    }

                    // Body keypoints
                    ForEach(Array(pose.bodyJoints.keys), id: \.self) { joint in
                        if let p = pose.bodyJoints[joint] {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 8, height: 8)
                                .position(convertNormalizedPoint(p, in: size))
                                .shadow(radius: 1)
                        }
                    }

                    // Hand keypoints (up to 2 hands)
                    ForEach(0..<pose.hands.count, id: \.self) { handIndex in
                        let hand = pose.hands[handIndex]
                        ForEach(Array(hand.keys), id: \.self) { joint in
                            if let p = hand[joint] {
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 6, height: 6)
                                    .position(convertNormalizedPoint(p, in: size))
                            }
                        }
                    }
                }
                .allowsHitTesting(false)
            }

            // Top-centered warning
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

            // Top-left counters
            VStack(alignment: .leading, spacing: 4) {
                Text("Shots: \(detector.shots)")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                Text("Makes: \(detector.makes)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 52)       // sits just below the warning
            .padding(.leading, 18)   // nudge right so it never clips
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .animation(.easeInOut(duration: 0.2), value: message)
        .allowsHitTesting(false)
    }

    // Convert Vision normalized coordinates (0..1) to the overlay's coordinate space,
    // flipping Y because SwiftUI's origin is top-left.
    private func convertNormalizedPoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let x = point.x * size.width
        let y = (1.0 - point.y) * size.height
        return CGPoint(x: x, y: y)
    }
}
