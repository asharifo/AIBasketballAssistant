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
        ZStack {
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
                    .foregroundColor(.white)
                    .shadow(radius: 1)


                Text("Makes: \(detector.makes)")
                    .font(.footnote)
                    .foregroundColor(.white)
                    .shadow(radius: 1)
            }
            .padding(.top, 52)       // sits just below the warning
            .padding(.leading, 18)   // nudge right so it never clips
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .animation(.easeInOut(duration: 0.2), value: message)
        .allowsHitTesting(false)
    }
}





