import SwiftUI
import SwiftData

@main
struct AIBallzApp: App {
    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
        .modelContainer(for: ShotStats.self)
    }
}
