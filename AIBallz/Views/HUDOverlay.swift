import SwiftUI


struct HUDOverlay: View {
    @ObservedObject var detector: BallHoopDetector


    private var message: String? {
        let noBall = detector.balls.isEmpty
        let noHoop = detector.hoops.isEmpty
        if noBall && noHoop { return "Ball and hoop not detected" }
        if noBall { return "Ball not detected" }
        if noHoop { return "Hoop not detected" }
        return nil
    }

    var body: some View {
        Group {
            if let message {
                Text(message)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(radius: 2)
                    .accessibilityLabel(message)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: message)
    }
}





