//
//  ShotHistoryView.swift
//  AIBallz
//
//  Created by Amir Sharifov on 2025-08-07.
//

import SwiftUI
import Charts
import SwiftData

struct ShotHistoryView : View {
    @State private var selectedTimeRange: TimeRange = .week
    
    enum TimeRange: String, CaseIterable {
        case week = "Week"
        case month = "Month"
        case all = "All Time"
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                HeaderSection()
                TimeRangePicker()
                StatsSection()
                RecentShotsSection()
            }
            .padding(.horizontal)
        }
        .navigationBarHidden(true)
    }
    
    
    @ViewBuilder
    private func HeaderSection() -> some View {
        VStack(spacing: 16) {
            Text("Shot History")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(.primary)
            
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2)) {
                StatBubbleView(
                    title: "Overall Accuracy",
                    value: String(format: "%.1f%%", 0),
                    icon: "target",
                    color: .orange)
                StatBubbleView(
                    title: "Recent Accuracy",
                    value: String(format: "%.1f%%", 0),
                    icon: "chart.line.uptrend.xyaxis",
                    color: .teal)
                StatBubbleView(
                    title: "Total Shots",
                    value: "0",
                    icon: "figure.basketball",
                    color: .blue)
                StatBubbleView(
                    title: "Shots Made",
                    value: "0",
                    icon: "checkmark.circle.fill",
                    color: .green)
            }
            .frame(maxWidth: .infinity)
        }
    }
    
    @ViewBuilder
    private func TimeRangePicker() -> some View {
        Picker("Time Range", selection: $selectedTimeRange) {
            ForEach(TimeRange.allCases, id: \.self) { range in
                Text(range.rawValue).tag(range)
            }
        }
        .pickerStyle(SegmentedPickerStyle())
    }
    
    @ViewBuilder
    private func StatsSection() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Statistics")
                .font(.headline)
                .foregroundColor(.primary)
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.1))
                .frame(height: 100)
                .overlay(
                    VStack {
                        Image(systemName: "chart.bar")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        Text("No data available")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                )
        }
    }
    
    @ViewBuilder
    private func RecentShotsSection() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Shots")
                .font(.headline)
                .foregroundColor(.primary)
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.1))
                .frame(height: 100)
                .overlay(
                    VStack {
                        Image(systemName: "basketball")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        Text("No shots recorded yet")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                )
        }
    }
}

struct StatBubbleView: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    var height: CGFloat = 120

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                Spacer()
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(value)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                    Text(title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .padding()
        .frame(maxWidth: .infinity)   // expand to full grid cell width
        .frame(height: height)        // identical height
        .background(                  // draw background after sizing
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.1))
        )
    }
}

#Preview {
    ShotHistoryView()
}

