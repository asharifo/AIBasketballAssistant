import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                VideoAnalysisView()
            }
            .tabItem {
                Image(systemName: "video.fill")
                Text("Analysis")
            }
            
            NavigationStack {
                ShotHistoryView()
            }
            .tabItem {
                Image(systemName: "chart.line.uptrend.xyaxis")
                Text("History")
            }
        }
        .tint(.orange)
    }
}

#Preview {
    MainTabView()
}
