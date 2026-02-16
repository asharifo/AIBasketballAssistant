import Foundation
import SwiftData

@Model
final class ShotRecord {
    static let pendingFeedbackText = "Form feedback not available yet."

    var timestamp: Date
    var isMake: Bool
    var shotIndex: Int
    var llmFormFeedback: String

    init(
        timestamp: Date = Date(),
        isMake: Bool,
        shotIndex: Int,
        llmFormFeedback: String = ShotRecord.pendingFeedbackText
    ) {
        self.timestamp = timestamp
        self.isMake = isMake
        self.shotIndex = shotIndex
        self.llmFormFeedback = llmFormFeedback
    }
}
