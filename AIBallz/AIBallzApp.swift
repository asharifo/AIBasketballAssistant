import SwiftUI
import SwiftData

@main
struct AIBallzApp: App {
    @StateObject private var authManager = AuthManager()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(authManager)
        }
        .modelContainer(for: ShotRecord.self)
    }
}
