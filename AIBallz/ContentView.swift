//
//  ContentView.swift
//  AIBallz
//
//  Created by Amir Sharifov on 2025-08-06.
//

import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            VideoAnalysisView()
                .tabItem {
                    Image(systemName: "video.fill")
                    Text("Analysis")
                }
            
            ShotHistoryView()
                .tabItem {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                    Text("History")
                }
        }
        .accentColor(.orange)
    }
}

#Preview {
    MainTabView()
}
