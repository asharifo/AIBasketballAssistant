import AuthenticationServices
import UIKit

@MainActor
final class WebAuthenticationSessionHandler: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func start(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error = error as? ASWebAuthenticationSessionError,
                   error.code == .canceledLogin {
                    continuation.resume(throwing: WebAuthenticationSessionError.cancelled)
                    return
                }

                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let callbackURL else {
                    continuation.resume(throwing: WebAuthenticationSessionError.invalidCallback)
                    return
                }

                continuation.resume(returning: callbackURL)
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session

            guard session.start() else {
                continuation.resume(throwing: WebAuthenticationSessionError.unableToStart)
                self.session = nil
                return
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

enum WebAuthenticationSessionError: LocalizedError, Equatable {
    case cancelled
    case invalidCallback
    case unableToStart

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Authentication was cancelled."
        case .invalidCallback:
            return "Auth callback URL was invalid."
        case .unableToStart:
            return "Unable to start authentication session."
        }
    }
}
