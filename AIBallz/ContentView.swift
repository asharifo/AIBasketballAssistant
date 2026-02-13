import SwiftUI

struct AppRootView: View {
    @EnvironmentObject private var authManager: AuthManager

    var body: some View {
        Group {
            switch authManager.sessionState {
            case .loading:
                ProgressView("Checking session...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unauthenticated:
                AuthenticationView()
            case .authenticated:
                MainTabView()
            }
        }
    }
}

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

            NavigationStack {
                AccountView()
            }
            .tabItem {
                Image(systemName: "person.crop.circle")
                Text("Account")
            }
        }
        .tint(.orange)
    }
}

#Preview {
    MainTabView()
        .environmentObject(AuthManager())
}
