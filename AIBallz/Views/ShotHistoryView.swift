//
//  ShotHistoryView.swift
//  AIBallz
//
//  Created by Amir Sharifov on 2025-08-07.
//

import SwiftUI
import Charts

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
            
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 16) {
                StatBubbleView(
                    title: "Overall Accuracy",
                    value: String(format: "%.1f%%", 0),
                    icon: "target",
                    color: .orange
                )
                
                StatBubbleView(
                    title: "Recent Accuracy",
                    value: String(format: "%.1f%%", 0),
                    icon: "chart.line.uptrend.xyaxis",
                    color: .green
                )
            }
        }
        .padding(.horizontal)
    }
    
    @ViewBuilder
    private func TimeRangePicker() -> some View {
        Picker("Time Range", selection: $selectedTimeRange) {
            ForEach(TimeRange.allCases, id: \.self) { range in
                Text(range.rawValue).tag(range)
            }
        }
        .pickerStyle(SegmentedPickerStyle())
        .padding(.horizontal)
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
        .padding(.horizontal)
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
        .padding(.horizontal)
    }
}

struct StatBubbleView: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
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
        .background(Color.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
