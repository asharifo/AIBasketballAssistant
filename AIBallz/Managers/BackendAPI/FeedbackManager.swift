import Foundation
import CoreGraphics

struct FeedbackShotInput: Sendable {
    let shotIndex: Int
    let isMake: Bool
    let timestamp: Date
}

struct FeedbackManager {
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func requestFormFeedback(
        shot: FeedbackShotInput,
        poseWindow: [PoseFrame],
        detectionWindow: [BestDetectionFrame],
        bearerToken: String? = nil
    ) async throws -> String {
        let endpoint = try feedbackEndpointURL()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        let payload = ShotFeedbackRequest(
            shot: ShotPayload(
                shotIndex: shot.shotIndex,
                isMake: shot.isMake,
                timestamp: shot.timestamp
            ),
            poseWindow: poseWindow.map { PoseFramePayload(frame: $0) },
            detectionWindow: detectionWindow.map { DetectionFramePayload(frame: $0) }
        )
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackManagerError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw FeedbackManagerError.serverError(status: httpResponse.statusCode, body: bodyString)
        }

        let decoded = try decoder.decode(ShotFeedbackResponse.self, from: data)
        let feedback = decoded.feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !feedback.isEmpty else { throw FeedbackManagerError.emptyFeedback }
        return feedback
    }

    private func feedbackEndpointURL() throws -> URL {
        let base: String?
        if let env = ProcessInfo.processInfo.environment["FEEDBACK_API_BASE_URL"], !env.isEmpty {
            base = env
        } else {
            base = Bundle.main.object(forInfoDictionaryKey: "FEEDBACK_API_BASE_URL") as? String
        }

        guard let base, let baseURL = URL(string: base) else {
            throw FeedbackManagerError.missingBaseURL
        }

        return baseURL.appendingPathComponent("v1/shot-feedback")
    }
}

enum FeedbackManagerError: LocalizedError {
    case missingBaseURL
    case invalidResponse
    case serverError(status: Int, body: String)
    case emptyFeedback

    var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            return "Missing FEEDBACK_API_BASE_URL app configuration."
        case .invalidResponse:
            return "Invalid response from feedback backend."
        case .serverError(let status, let body):
            if body.isEmpty { return "Feedback backend error (\(status))." }
            return "Feedback backend error (\(status)): \(body)"
        case .emptyFeedback:
            return "Feedback backend returned empty feedback."
        }
    }
}

private struct ShotFeedbackRequest: Codable {
    let shot: ShotPayload
    let poseWindow: [PoseFramePayload]
    let detectionWindow: [DetectionFramePayload]
}

private struct ShotPayload: Codable {
    let shotIndex: Int
    let isMake: Bool
    let timestamp: Date
}

private struct PoseFramePayload: Codable {
    let timestamp: CFTimeInterval
    let bodyJoints: [String: PointPayload]
    let hands: [[String: PointPayload]]

    init(frame: PoseFrame) {
        self.timestamp = frame.timestamp
        self.bodyJoints = Dictionary(
            uniqueKeysWithValues: frame.bodyJoints.map { ($0.key.rawValue, PointPayload(point: $0.value)) }
        )
        self.hands = frame.hands.map { hand in
            Dictionary(uniqueKeysWithValues: hand.map { ($0.key.rawValue, PointPayload(point: $0.value)) })
        }
    }
}

private struct DetectionFramePayload: Codable {
    let timestamp: CFTimeInterval
    let ball: DetectionPayload?
    let hoop: DetectionPayload?

    init(frame: BestDetectionFrame) {
        self.timestamp = frame.timestamp
        self.ball = frame.ball.map(DetectionPayload.init)
        self.hoop = frame.hoop.map(DetectionPayload.init)
    }
}

private struct DetectionPayload: Codable {
    let confidence: Float
    let bbox: RectPayload

    init(_ detection: YOLODetection) {
        self.confidence = detection.confidence
        self.bbox = RectPayload(rect: detection.bbox)
    }
}

private struct PointPayload: Codable {
    let x: CGFloat
    let y: CGFloat

    init(point: CGPoint) {
        self.x = point.x
        self.y = point.y
    }
}

private struct RectPayload: Codable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.width
        self.height = rect.height
    }
}

private struct ShotFeedbackResponse: Codable {
    let feedback: String
}
