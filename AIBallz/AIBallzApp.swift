//
//  AIBallzApp.swift
//  AIBallz
//
//  Created by Amir Sharifov on 2025-08-06.
//

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
