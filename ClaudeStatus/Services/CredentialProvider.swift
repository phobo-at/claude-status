import Foundation
import Security

struct ClaudeCredential: Sendable {
    let accessToken: String
    let planName: String?
}

protocol CredentialProviding: Sendable {
    func credential() async throws -> ClaudeCredential
}

enum CredentialError: LocalizedError, Equatable, Sendable {
    case notFound
    case accessDenied
    case invalidPayload
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notFound:
            String(localized: "No Claude Code login found. Run “claude auth login” first.")
        case .accessDenied:
            String(localized: "Access to the Claude Code login was denied.")
        case .invalidPayload:
            String(localized: "The stored Claude Code login has an unknown format.")
        case let .keychain(status):
            String(localized: "The macOS Keychain could not be read (error \(status)).")
        }
    }
}

struct KeychainCredentialProvider: CredentialProviding {
    static let service = "Claude Code-credentials"
    private static let maximumPayloadSize = 64 * 1024

    private let account: String

    init(account: String = NSUserName()) {
        self.account = account
    }

    func credential() async throws -> ClaudeCredential {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  data.count <= Self.maximumPayloadSize,
                  let credential = Self.credential(in: data)
            else {
                throw CredentialError.invalidPayload
            }
            return credential
        case errSecItemNotFound:
            throw CredentialError.notFound
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            throw CredentialError.accessDenied
        default:
            throw CredentialError.keychain(status)
        }
    }

    static func credential(in data: Data) -> ClaudeCredential? {
        guard data.count <= maximumPayloadSize,
              let payload = try? JSONDecoder().decode(CredentialPayload.self, from: data),
              Self.isValidToken(payload.claudeAiOauth.accessToken)
        else {
            return nil
        }

        return ClaudeCredential(
            accessToken: payload.claudeAiOauth.accessToken,
            planName: Self.planName(subscriptionType: payload.claudeAiOauth.subscriptionType)
        )
    }

    static func planName(subscriptionType: String?) -> String? {
        switch subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "max": "Max"
        case "pro": "Pro"
        case "team": "Team"
        case "enterprise": "Enterprise"
        default: nil
        }
    }

    private static func isValidToken(_ token: String) -> Bool {
        !token.isEmpty
            && token.utf8.count <= 16 * 1024
            && token.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private struct CredentialPayload: Decodable {
        let claudeAiOauth: OAuthPayload
    }

    private struct OAuthPayload: Decodable {
        let accessToken: String
        let subscriptionType: String?
    }
}
