import Foundation
import CryptoKit

struct AuthUser {
    let subject: String
    let email: String?
    let name: String?
}

@MainActor
final class AuthManager: ObservableObject {
    enum SessionState {
        case loading
        case unauthenticated
        case authenticated
    }

    @Published private(set) var sessionState: SessionState = .loading
    @Published private(set) var currentUser: AuthUser?
    @Published private(set) var isBusy: Bool = false
    @Published var errorMessage: String?

    private let credentialsStore: AuthCredentialsStore
    private let webSessionHandler: WebAuthenticationSessionHandler
    private let urlSession: URLSession

    private let config: Auth0Config?
    private var credentials: AuthCredentials?

    init(
        credentialsStore: AuthCredentialsStore = AuthCredentialsStore(),
        webSessionHandler: WebAuthenticationSessionHandler? = nil,
        urlSession: URLSession = .shared
    ) {
        self.credentialsStore = credentialsStore
        self.webSessionHandler = webSessionHandler ?? WebAuthenticationSessionHandler()
        self.urlSession = urlSession

        do {
            self.config = try Auth0Config.loadFromInfoPlist()
        } catch {
            self.config = nil
            self.errorMessage = error.localizedDescription
        }

        Task {
            await bootstrapSession()
        }
    }

    func login() async {
        await startWebAuthentication(screenHint: "login")
    }

    func register() async {
        await startWebAuthentication(screenHint: "signup")
    }

    func logout() async {
        guard let config else {
            clearLocalSession()
            return
        }

        setBusy(true)
        defer { setBusy(false) }

        if let logoutURL = buildLogoutURL(config: config) {
            do {
                _ = try await webSessionHandler.start(
                    url: logoutURL,
                    callbackScheme: config.callbackScheme
                )
            } catch {
                // Continue with local credential cleanup even if browser logout fails.
            }
        }

        clearLocalSession()
    }

    func validAccessTokenIfAvailable() async -> String? {
        do {
            let creds = try await ensureValidCredentials()
            return creds.accessToken
        } catch {
            return nil
        }
    }

    private func bootstrapSession() async {
        guard config != nil else {
            sessionState = .unauthenticated
            return
        }

        do {
            guard let stored = try credentialsStore.load() else {
                sessionState = .unauthenticated
                return
            }

            credentials = stored
            if stored.needsRefresh() {
                _ = try await refreshSession()
            } else {
                applyAuthenticatedState(with: stored)
            }
        } catch {
            clearLocalSession()
            errorMessage = error.localizedDescription
        }
    }

    private func startWebAuthentication(screenHint: String) async {
        guard let config else {
            sessionState = .unauthenticated
            errorMessage = "Auth0 configuration is missing."
            return
        }

        setBusy(true)
        defer { setBusy(false) }

        do {
            let state = PKCE.randomURLSafeString(length: 32)
            let nonce = PKCE.randomURLSafeString(length: 32)
            let codeVerifier = PKCE.randomURLSafeString(length: 64)
            let codeChallenge = PKCE.codeChallenge(from: codeVerifier)

            guard let authorizeURL = buildAuthorizeURL(
                config: config,
                state: state,
                nonce: nonce,
                codeChallenge: codeChallenge,
                screenHint: screenHint
            ) else {
                throw AuthManagerError.invalidAuthorizeURL
            }

            let callbackURL = try await webSessionHandler.start(
                url: authorizeURL,
                callbackScheme: config.callbackScheme
            )

            let callbackParams = try parseCallbackURL(callbackURL)
            guard callbackParams.state == state else {
                throw AuthManagerError.stateMismatch
            }

            let tokenResponse = try await exchangeAuthorizationCode(
                code: callbackParams.code,
                codeVerifier: codeVerifier,
                config: config
            )

            let newCredentials = mergeTokenResponse(tokenResponse, current: nil)
            try credentialsStore.save(newCredentials)
            credentials = newCredentials
            applyAuthenticatedState(with: newCredentials)
            errorMessage = nil
        } catch {
            if let authError = error as? WebAuthenticationSessionError, authError == .cancelled {
                return
            }
            errorMessage = error.localizedDescription
            sessionState = .unauthenticated
        }
    }

    private func ensureValidCredentials() async throws -> AuthCredentials {
        guard var current = credentials else {
            throw AuthManagerError.notAuthenticated
        }

        if current.needsRefresh() {
            current = try await refreshSession()
        }
        return current
    }

    private func refreshSession() async throws -> AuthCredentials {
        guard let config else {
            throw AuthManagerError.configurationMissing
        }
        guard let current = credentials else {
            throw AuthManagerError.notAuthenticated
        }
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            throw AuthManagerError.refreshTokenMissing
        }

        let tokenResponse = try await exchangeRefreshToken(
            refreshToken: refreshToken,
            config: config
        )
        let updated = mergeTokenResponse(tokenResponse, current: current)
        try credentialsStore.save(updated)
        credentials = updated
        applyAuthenticatedState(with: updated)
        return updated
    }

    private func mergeTokenResponse(
        _ response: Auth0TokenResponse,
        current: AuthCredentials?
    ) -> AuthCredentials {
        let refresh = response.refreshToken ?? current?.refreshToken
        return AuthCredentials(
            accessToken: response.accessToken,
            idToken: response.idToken ?? current?.idToken,
            refreshToken: refresh,
            tokenType: response.tokenType,
            scope: response.scope ?? current?.scope,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn))
        )
    }

    private func applyAuthenticatedState(with credentials: AuthCredentials) {
        self.credentials = credentials
        self.currentUser = Self.decodeUser(fromIDToken: credentials.idToken)
        self.sessionState = .authenticated
    }

    private func clearLocalSession() {
        do {
            try credentialsStore.clear()
        } catch {
            // Nothing user-visible to do here.
        }
        credentials = nil
        currentUser = nil
        sessionState = .unauthenticated
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
    }
}

private extension AuthManager {
    func buildAuthorizeURL(
        config: Auth0Config,
        state: String,
        nonce: String,
        codeChallenge: String,
        screenHint: String
    ) -> URL? {
        var components = URLComponents(url: config.issuerURL.appendingPathComponent("authorize"), resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "screen_hint", value: screenHint)
        ]

        if let audience = config.audience, !audience.isEmpty {
            items.append(URLQueryItem(name: "audience", value: audience))
        }

        components?.queryItems = items
        return components?.url
    }

    func buildLogoutURL(config: Auth0Config) -> URL? {
        var components = URLComponents(url: config.issuerURL.appendingPathComponent("v2/logout"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "returnTo", value: config.logoutRedirectURI)
        ]
        return components?.url
    }

    func parseCallbackURL(_ url: URL) throws -> AuthCallbackParameters {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AuthManagerError.invalidCallback
        }

        let queryItems = components.queryItems ?? []
        let values = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })

        if let error = values["error"] {
            let description = values["error_description"] ?? error
            throw AuthManagerError.auth0ReturnedError(description)
        }

        guard let code = values["code"], !code.isEmpty else {
            throw AuthManagerError.missingAuthorizationCode
        }
        guard let state = values["state"], !state.isEmpty else {
            throw AuthManagerError.missingState
        }

        return AuthCallbackParameters(code: code, state: state)
    }

    func exchangeAuthorizationCode(
        code: String,
        codeVerifier: String,
        config: Auth0Config
    ) async throws -> Auth0TokenResponse {
        let body = Auth0TokenRequest(
            grantType: "authorization_code",
            clientID: config.clientID,
            code: code,
            codeVerifier: codeVerifier,
            redirectURI: config.redirectURI,
            refreshToken: nil,
            audience: config.audience
        )
        return try await requestToken(body: body, config: config)
    }

    func exchangeRefreshToken(
        refreshToken: String,
        config: Auth0Config
    ) async throws -> Auth0TokenResponse {
        let body = Auth0TokenRequest(
            grantType: "refresh_token",
            clientID: config.clientID,
            code: nil,
            codeVerifier: nil,
            redirectURI: nil,
            refreshToken: refreshToken,
            audience: config.audience
        )
        return try await requestToken(body: body, config: config)
    }

    func requestToken(
        body: Auth0TokenRequest,
        config: Auth0Config
    ) async throws -> Auth0TokenResponse {
        var request = URLRequest(url: config.issuerURL.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthManagerError.invalidHTTPResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            if let auth0Error = try? JSONDecoder().decode(Auth0ErrorResponse.self, from: data) {
                throw AuthManagerError.auth0ReturnedError(auth0Error.errorDescription ?? auth0Error.error)
            }
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw AuthManagerError.tokenExchangeFailed(statusCode: http.statusCode, responseBody: bodyText)
        }

        return try JSONDecoder().decode(Auth0TokenResponse.self, from: data)
    }

    static func decodeUser(fromIDToken idToken: String?) -> AuthUser? {
        guard
            let idToken,
            let payload = decodeJWTPayload(idToken),
            let subject = payload["sub"] as? String
        else {
            return nil
        }

        return AuthUser(
            subject: subject,
            email: payload["email"] as? String,
            name: payload["name"] as? String
        )
    }

    static func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count == 3 else { return nil }

        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = payload.count % 4
        if remainder > 0 {
            payload.append(String(repeating: "=", count: 4 - remainder))
        }

        guard let data = Data(base64Encoded: payload) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String: Any]
    }
}

private struct AuthCallbackParameters {
    let code: String
    let state: String
}

private struct Auth0TokenRequest: Encodable {
    let grantType: String
    let clientID: String
    let code: String?
    let codeVerifier: String?
    let redirectURI: String?
    let refreshToken: String?
    let audience: String?

    enum CodingKeys: String, CodingKey {
        case grantType = "grant_type"
        case clientID = "client_id"
        case code
        case codeVerifier = "code_verifier"
        case redirectURI = "redirect_uri"
        case refreshToken = "refresh_token"
        case audience
    }
}

private struct Auth0TokenResponse: Decodable {
    let accessToken: String
    let idToken: String?
    let refreshToken: String?
    let tokenType: String
    let scope: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case idToken = "id_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case scope
        case expiresIn = "expires_in"
    }
}

private struct Auth0ErrorResponse: Decodable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

enum AuthManagerError: LocalizedError {
    case configurationMissing
    case invalidAuthorizeURL
    case invalidCallback
    case missingAuthorizationCode
    case missingState
    case stateMismatch
    case invalidHTTPResponse
    case refreshTokenMissing
    case notAuthenticated
    case auth0ReturnedError(String)
    case tokenExchangeFailed(statusCode: Int, responseBody: String)

    var errorDescription: String? {
        switch self {
        case .configurationMissing:
            return "Auth0 configuration is missing."
        case .invalidAuthorizeURL:
            return "Unable to build Auth0 authorize URL."
        case .invalidCallback:
            return "Invalid callback from Auth0."
        case .missingAuthorizationCode:
            return "Authorization code was missing."
        case .missingState:
            return "Auth state parameter was missing."
        case .stateMismatch:
            return "Auth request state did not match callback."
        case .invalidHTTPResponse:
            return "Auth0 returned an invalid HTTP response."
        case .refreshTokenMissing:
            return "Refresh token missing. Please log in again."
        case .notAuthenticated:
            return "User is not authenticated."
        case .auth0ReturnedError(let details):
            return "Auth0 error: \(details)"
        case .tokenExchangeFailed(let statusCode, let body):
            if body.isEmpty { return "Token exchange failed (\(statusCode))." }
            return "Token exchange failed (\(statusCode)): \(body)"
        }
    }
}

private enum PKCE {
    static func randomURLSafeString(length: Int) -> String {
        let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<length).compactMap { _ in characters.randomElement() })
    }

    static func codeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let digest = SHA256.hash(data: data)
        return Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
