import Foundation

/// The token pair from a self-contained sign-in, persisted to our own Keychain item. This
/// is *our* pair — refreshing it rotates our refresh token, never Claude Code's, so the CLI
/// stays logged in.
public struct OAuthTokens: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// Raw token-endpoint response. `expires_in` is seconds-from-now, so it's turned into an
/// absolute `expiresAt` at the moment of decode by the client.
struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Double

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}
