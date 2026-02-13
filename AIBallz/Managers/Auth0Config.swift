import Foundation

struct Auth0Config {
    let domain: String
    let clientID: String
    let audience: String?
    let callbackScheme: String
    let bundleIdentifier: String

    var issuerURL: URL {
        URL(string: "https://\(domain)")!
    }

    var redirectURI: String {
        "\(callbackScheme)://\(domain)/ios/\(bundleIdentifier)/callback"
    }

    var logoutRedirectURI: String {
        "\(callbackScheme)://\(domain)/ios/\(bundleIdentifier)/logout"
    }

    static func loadFromInfoPlist() throws -> Auth0Config {
        let bundle = Bundle.main

        guard let domain = bundle.object(forInfoDictionaryKey: "AUTH0_DOMAIN") as? String,
              !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Auth0ConfigError.missingValue(key: "AUTH0_DOMAIN")
        }

        guard let clientID = bundle.object(forInfoDictionaryKey: "AUTH0_CLIENT_ID") as? String,
              !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Auth0ConfigError.missingValue(key: "AUTH0_CLIENT_ID")
        }

        guard let callbackScheme = bundle.object(forInfoDictionaryKey: "AUTH0_CALLBACK_SCHEME") as? String,
              !callbackScheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Auth0ConfigError.missingValue(key: "AUTH0_CALLBACK_SCHEME")
        }

        guard let bundleIdentifier = bundle.bundleIdentifier,
              !bundleIdentifier.isEmpty else {
            throw Auth0ConfigError.missingBundleIdentifier
        }

        let audience = (bundle.object(forInfoDictionaryKey: "AUTH0_AUDIENCE") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Auth0Config(
            domain: domain,
            clientID: clientID,
            audience: audience?.isEmpty == true ? nil : audience,
            callbackScheme: callbackScheme,
            bundleIdentifier: bundleIdentifier
        )
    }
}

enum Auth0ConfigError: LocalizedError {
    case missingValue(key: String)
    case missingBundleIdentifier

    var errorDescription: String? {
        switch self {
        case .missingValue(let key):
            return "Missing \(key) in Info.plist."
        case .missingBundleIdentifier:
            return "Unable to read app bundle identifier."
        }
    }
}
