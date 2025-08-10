//
//  VideoAnalysisView.swift
//  AIBallz
//
//  Created by Amir Sharifov on 2025-08-07.
//

import SwiftUI

struct VideoAnalysisView: View {
    
    var body: some View {
        VStack {
            VStack {
                Text("Shot Analysis")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                Text("Record or upload a video for instant feedback")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
