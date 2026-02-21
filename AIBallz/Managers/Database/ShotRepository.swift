import Foundation
import SwiftData

@MainActor
final class ShotRepository {
    struct PersistedShot {
        let shotIndex: Int
        let isMake: Bool
        let timestamp: Date
    }

    private let modelContext: ModelContext
    private var nextShotIndexCache: Int?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func persistShot(isMake: Bool, timestamp: Date = Date()) throws -> PersistedShot {
        let shotIndex = try nextShotIndex()
        let shot = ShotRecord(
            timestamp: timestamp,
            isMake: isMake,
            shotIndex: shotIndex,
            llmFormFeedback: ShotRecord.pendingFeedbackText
        )

        modelContext.insert(shot)
        try modelContext.save()

        return PersistedShot(
            shotIndex: shot.shotIndex,
            isMake: shot.isMake,
            timestamp: shot.timestamp
        )
    }

    func updateFeedback(forShotIndex shotIndex: Int, feedback: String) throws {
        var descriptor = FetchDescriptor<ShotRecord>(
            predicate: #Predicate { $0.shotIndex == shotIndex },
            sortBy: [SortDescriptor(\ShotRecord.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        guard let shot = try modelContext.fetch(descriptor).first else { return }
        shot.llmFormFeedback = feedback
        try modelContext.save()
    }

    private func nextShotIndex() throws -> Int {
        if let cached = nextShotIndexCache {
            nextShotIndexCache = cached + 1
            return cached
        }

        var descriptor = FetchDescriptor<ShotRecord>(
            sortBy: [SortDescriptor(\ShotRecord.shotIndex, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        let latest = try modelContext.fetch(descriptor).first?.shotIndex ?? 0
        let next = latest + 1
        nextShotIndexCache = next + 1
        return next
    }
}
