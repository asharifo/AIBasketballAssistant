import SwiftUI
import SwiftData
import Charts

struct ShotHistoryView: View {
    @Query(sort: \ShotRecord.timestamp, order: .reverse) private var shotRecords: [ShotRecord]
    @State private var selectedTimeRange: TimeRange = .week

    enum TimeRange: String, CaseIterable {
        case week = "Week"
        case month = "Month"
        case all = "All Time"
    }

    private struct ShotChartPoint: Identifiable {
        let bucketDate: Date
        let attempts: Int
        let makes: Int

        var id: Date { bucketDate }
    }

    private var filteredRecords: [ShotRecord] {
        switch selectedTimeRange {
        case .week:
            return recordsSince(days: 7)
        case .month:
            return recordsSince(days: 30)
        case .all:
            return shotRecords
        }
    }

    private var totalShots: Int { filteredRecords.count }
    private var totalMakes: Int { filteredRecords.filter(\.isMake).count }
    private var totalMisses: Int { max(0, totalShots - totalMakes) }
    private var accuracy: Double {
        guard totalShots > 0 else { return 0 }
        return (Double(totalMakes) / Double(totalShots)) * 100
    }

    private var chartData: [ShotChartPoint] {
        let calendar = Calendar.current
        let now = Date()

        switch selectedTimeRange {
        case .week:
            let start = calendar.startOfDay(
                for: calendar.date(byAdding: .day, value: -6, to: now) ?? now
            )
            return dailyPoints(from: start, days: 7)
        case .month:
            let start = calendar.startOfDay(
                for: calendar.date(byAdding: .day, value: -29, to: now) ?? now
            )
            return dailyPoints(from: start, days: 30)
        case .all:
            return monthlyPoints()
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                metricsHeader
                rangePicker
                chartCard
                recentShotsPanel
            }
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
        .navigationTitle("Shot History")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var metricsHeader: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 12) {
            StatCard(
                title: "Total Shots",
                value: "\(totalShots)",
                icon: "figure.basketball",
                color: .blue
            )
            StatCard(
                title: "Shot Accuracy",
                value: String(format: "%.1f%%", accuracy),
                icon: "target",
                color: .orange
            )
            StatCard(
                title: "Shots Made",
                value: "\(totalMakes)",
                icon: "checkmark.circle.fill",
                color: .green
            )
            StatCard(
                title: "Shots Missed",
                value: "\(totalMisses)",
                icon: "xmark.circle.fill",
                color: .red
            )
        }
    }

    private var rangePicker: some View {
        Picker("Time Range", selection: $selectedTimeRange) {
            ForEach(TimeRange.allCases, id: \.self) { range in
                Text(range.rawValue).tag(range)
            }
        }
        .pickerStyle(.segmented)
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shot Diagram")
                .font(.headline)

            if chartData.isEmpty {
                ContentUnavailableView(
                    "No shots in this range",
                    systemImage: "chart.bar.xaxis"
                )
                .frame(height: 220)
            } else {
                Chart(chartData) { point in
                    BarMark(
                        x: .value("Time", point.bucketDate, unit: chartUnit),
                        y: .value("Attempts", point.attempts)
                    )
                    .foregroundStyle(by: .value("Series", "Attempts"))
                    .position(by: .value("Series", "Attempts"))

                    BarMark(
                        x: .value("Time", point.bucketDate, unit: chartUnit),
                        y: .value("Makes", point.makes)
                    )
                    .foregroundStyle(by: .value("Series", "Makes"))
                    .position(by: .value("Series", "Makes"))
                }
                .chartForegroundStyleScale([
                    "Attempts": Color.blue,
                    "Makes": Color.green
                ])
                .chartLegend(position: .top, spacing: 12)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6))
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 220)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.gray.opacity(0.08))
        )
    }

    private var recentShotsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Shots")
                .font(.headline)

            if shotRecords.isEmpty {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
                    .frame(height: 120)
                    .overlay(
                        VStack(spacing: 6) {
                            Image(systemName: "basketball")
                                .font(.system(size: 34))
                                .foregroundColor(.gray)
                            Text("No shots recorded yet")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(shotRecords) { shot in
                            NavigationLink {
                                ShotDetailView(shot: shot)
                            } label: {
                                ShotRowView(shot: shot)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.gray.opacity(0.08))
        )
    }

    private var chartUnit: Calendar.Component {
        switch selectedTimeRange {
        case .week, .month:
            return .day
        case .all:
            return .month
        }
    }

    private func recordsSince(days: Int) -> [ShotRecord] {
        let now = Date()
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        return shotRecords.filter { $0.timestamp >= cutoff }
    }

    private func dailyPoints(from startDate: Date, days: Int) -> [ShotChartPoint] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredRecords) { record in
            calendar.startOfDay(for: record.timestamp)
        }

        return (0..<days).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDate) else { return nil }
            let bucketRecords = grouped[day] ?? []
            return ShotChartPoint(
                bucketDate: day,
                attempts: bucketRecords.count,
                makes: bucketRecords.filter(\.isMake).count
            )
        }
    }

    private func monthlyPoints() -> [ShotChartPoint] {
        let calendar = Calendar.current
        guard let oldestRecord = shotRecords.last else { return [] }

        let startMonth = monthStart(for: oldestRecord.timestamp)
        let endMonth = monthStart(for: Date())

        let grouped = Dictionary(grouping: shotRecords) { record in
            monthStart(for: record.timestamp)
        }

        var points: [ShotChartPoint] = []
        var monthCursor = startMonth

        while monthCursor <= endMonth {
            let bucketRecords = grouped[monthCursor] ?? []
            points.append(
                ShotChartPoint(
                    bucketDate: monthCursor,
                    attempts: bucketRecords.count,
                    makes: bucketRecords.filter(\.isMake).count
                )
            )

            guard let next = calendar.date(byAdding: .month, value: 1, to: monthCursor) else { break }
            monthCursor = next
        }

        return points
    }

    private func monthStart(for date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? date
    }
}

private struct StatCard: View {
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
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.1))
        )
    }
}

private struct ShotRowView: View {
    let shot: ShotRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: shot.isMake ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title3)
                .foregroundColor(shot.isMake ? .green : .red)

            VStack(alignment: .leading, spacing: 3) {
                Text("Shot #\(shot.shotIndex)")
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                Text(shot.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.gray.opacity(0.1))
        )
    }
}

#Preview {
    NavigationStack {
        ShotHistoryView()
    }
}
