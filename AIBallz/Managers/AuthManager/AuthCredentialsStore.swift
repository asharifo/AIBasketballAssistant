import Foundation
import Security

struct AuthCredentials: Codable {
    var accessToken: String
    var idToken: String?
    var refreshToken: String?
    var tokenType: String
    var scope: String?
    var expiresAt: Date

    func needsRefresh(leeway: TimeInterval = 60) -> Bool {
        expiresAt <= Date().addingTimeInterval(leeway)
    }
}

final class AuthCredentialsStore {
    private let service: String
    private let account = "auth0_credentials_v1"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(service: String = "\(Bundle.main.bundleIdentifier ?? "AIBallz").auth") {
        self.service = service
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
    }

    func save(_ credentials: AuthCredentials) throws {
        let data = try encoder.encode(credentials)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AuthCredentialsStoreError.keychain(status: addStatus)
            }
            return
        }

        throw AuthCredentialsStoreError.keychain(status: updateStatus)
    }

    func load() throws -> AuthCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw AuthCredentialsStoreError.keychain(status: status)
        }

        guard let data = result as? Data else {
            throw AuthCredentialsStoreError.invalidData
        }
        return try decoder.decode(AuthCredentials.self, from: data)
    }

    func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthCredentialsStoreError.keychain(status: status)
        }
    }
}

enum AuthCredentialsStoreError: LocalizedError {
    case keychain(status: OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "Keychain error (\(status))."
        case .invalidData:
            return "Stored credentials were corrupted."
        }
    }
}
