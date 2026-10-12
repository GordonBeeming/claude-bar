import Foundation

/// The token pair from a self-contained sign-in, persisted to our own Keychain item. This
/// is *our* pair — refreshing it rotates our refresh token, never Claude Code's, so the CLI
/// stays logged in.
public struct OAuthTokens: Codable, Sendable, Equatable {
    /// What a pre-scope grant decodes as: "we don't know what this token can do", not "it can
    /// do nothing" — hence `isStale` retiring it rather than trusting it.
    public static let unknownScope = ""

    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    /// The server's answer, not our request: it echoes `scope` on both exchange and refresh.
    public let scope: String

    public init(accessToken: String, refreshToken: String, expiresAt: Date, scope: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken, refreshToken, expiresAt, scope
    }

    /// Items written before this field existed have no `scope` key, and a synthesized decode
    /// would throw on them — silently dropping those users into the Claude Code fallback.
    /// Decoding as unknown lets `isStale` retire them deliberately, with Settings saying why.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decode(String.self, forKey: .refreshToken)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? Self.unknownScope
    }

    /// True when a stored grant is one this build wouldn't ask for today — unknown, or wider
    /// than we now request, which is how an existing `org:create_api_key` token gets caught.
    /// Equal-or-narrower is kept: re-authing someone already tighter than needed is churn for
    /// no gain. Compared as sets, so scope order never forces a spurious reset.
    public static func isStale(storedScope: String, requestedScope: String) -> Bool {
        let stored = Set(storedScope.split(separator: " ").map(String.init))
        guard !stored.isEmpty else { return true }
        return !stored.isSubset(of: Set(requestedScope.split(separator: " ").map(String.init)))
    }
}

/// Raw token-endpoint response. `expires_in` is seconds-from-now, so it's turned into an
/// absolute `expiresAt` at the moment of decode by the client.
struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Double
    /// Optional defensively only — the live endpoint sends it on exchange and refresh alike,
    /// but failing sign-in over a field we can substitute would be the wrong trade.
    let scope: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
    }
}
