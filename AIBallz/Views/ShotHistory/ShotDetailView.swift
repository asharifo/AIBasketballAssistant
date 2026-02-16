import SwiftUI

struct ShotDetailView: View {
    let shot: ShotRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard
                metadataCard
                feedbackCard
            }
            .padding()
        }
        .navigationTitle("Shot #\(shot.shotIndex)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Result")
                .font(.headline)

            HStack(spacing: 10) {
                Image(systemName: shot.isMake ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(shot.isMake ? .green : .red)

                Text(shot.isMake ? "Make" : "Miss")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.gray.opacity(0.1))
        )
    }

    private var metadataCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shot Info")
                .font(.headline)

            infoRow(label: "Shot Number", value: "#\(shot.shotIndex)")
            infoRow(
                label: "Recorded At",
                value: shot.timestamp.formatted(date: .complete, time: .standard)
            )
            infoRow(label: "Data Source", value: "In-app shot tracking")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.gray.opacity(0.1))
        )
    }

    private var feedbackCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LLM Form Feedback")
                .font(.headline)

            Text(shot.llmFormFeedback)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.gray.opacity(0.08))
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.gray.opacity(0.1))
        )
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

#Preview {
    NavigationStack {
        ShotDetailView(shot: ShotRecord(isMake: true, shotIndex: 12))
    }
}
