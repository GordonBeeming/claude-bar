import Foundation
import Security

/// Reads the Claude Code CLI's OAuth access token so this app can call the same
/// usage endpoint the CLI does. Strictly read-only — never writes to Keychain and
/// never touches the refresh token, since rotating credentials that belong to
/// another tool isn't this app's job.
public struct CredentialsProvider: Sendable {
    private let keychainService: String
    private let credentialsFile: URL

    public init(account: ClaudeAccount = .standard()) {
        self.keychainService = account.keychainService
        self.credentialsFile = account.credentialsFileURL
    }

    /// - Important: Call off the main actor. `SecItemCopyMatching` can block on a
    ///   Keychain consent dialog the first time this app requests the item.
    public func loadAccessToken() -> String? {
        if let token = loadFromKeychain() {
            return token
        }
        return loadFromCredentialsFile()
    }

    private func loadFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }

        return accessToken(from: data)
    }

    private func loadFromCredentialsFile() -> String? {
        guard let data = try? Data(contentsOf: credentialsFile) else {
            return nil
        }
        return accessToken(from: data)
    }

    private func accessToken(from data: Data) -> String? {
        struct Credentials: Decodable {
            struct OAuth: Decodable {
                let accessToken: String
            }
            let claudeAiOauth: OAuth
        }

        return try? JSONDecoder().decode(Credentials.self, from: data).claudeAiOauth.accessToken
    }
}
