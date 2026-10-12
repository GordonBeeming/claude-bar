import Foundation

/// Drives the self-contained OAuth authorization-code + refresh flow against Claude Code's
/// OAuth client. Network calls mirror `UsageClient`'s shape; the URL building and the
/// refresh-timing decision are pure so they can be unit-tested without a server.
public struct OAuthClient: Sendable {
    public enum OAuthError: Error, Equatable {
        case http(Int)
        case malformedResponse
        case stateMismatch
    }

    public init() {}

    /// Builds the browser authorize URL. `code=true` makes the callback render the code for
    /// the user to copy (the manual-code flow). Pure — unit-tested for exact params.
    public static func authorizeURL(challenge: String, state: String) -> URL {
        var components = URLComponents(url: OAuthConfig.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: OAuthConfig.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: OAuthConfig.redirectURI),
            URLQueryItem(name: "scope", value: OAuthConfig.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        // Force-unwrap is safe: a valid base URL plus well-formed query items always resolves.
        return components.url!
    }

    /// The user pastes what the callback page shows. Claude Code's page renders the code and
    /// state joined by `#` (`<code>#<state>`); accept a bare code too. Returns the code only
    /// after confirming the returned state matches the one we sent.
    public static func parseCallbackCode(_ pasted: String, expectedState: String) throws -> String {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let code = String(parts[0])
        if parts.count == 2 {
            guard String(parts[1]) == expectedState else { throw OAuthError.stateMismatch }
        }
        guard !code.isEmpty else { throw OAuthError.malformedResponse }
        return code
    }

    /// Exchanges an authorization code for a token pair.
    public func exchange(code: String, verifier: String, state: String) async throws -> OAuthTokens {
        try await postToken([
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": OAuthConfig.clientID,
            "redirect_uri": OAuthConfig.redirectURI,
            "code_verifier": verifier
        ], fallbackScope: OAuthConfig.scopes)
    }

    /// Trades a refresh token for a fresh pair. Our refresh token, so this never disturbs
    /// Claude Code's credentials.
    ///
    /// `grantedScope` carries the stored grant forward instead of assuming `OAuthConfig.scopes`:
    /// a refresh inherits the original grant's scope, so re-deriving it would relabel a wide
    /// legacy token as narrow and defeat the staleness check meant to retire it.
    public func refresh(refreshToken: String, grantedScope: String) async throws -> OAuthTokens {
        try await postToken([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": OAuthConfig.clientID
        ], fallbackScope: grantedScope)
    }

    /// Asks Anthropic to revoke the grant. Verified live: revoking the refresh token also kills
    /// the access token issued with it (refresh then fails `invalid_grant`, usage 401), so one
    /// call retires the whole grant. `token_type_hint` and `client_id` are both required;
    /// omitting either gets a generic 400. A 200 only means the request was well-formed — per
    /// RFC 7009 the endpoint answers 200 for tokens it doesn't recognise.
    public func revoke(refreshToken: String) async throws {
        _ = try await send(cliRequest(url: OAuthConfig.revokeURL, body: [
            "token": refreshToken,
            "token_type_hint": "refresh_token",
            "client_id": OAuthConfig.clientID
        ]))
    }

    /// True when a stored token is at or past its expiry minus a safety buffer, so callers
    /// refresh a little early rather than racing the boundary. Pure — unit-tested.
    public static func needsRefresh(expiresAt: Date, now: Date, buffer: TimeInterval = 120) -> Bool {
        now.addingTimeInterval(buffer) >= expiresAt
    }

    private func postToken(_ body: [String: String], fallbackScope: String) async throws -> OAuthTokens {
        let data = try await send(cliRequest(url: OAuthConfig.tokenURL, body: body))
        guard let decoded = try? JSONDecoder().decode(OAuthTokenResponse.self, from: data) else {
            throw OAuthError.malformedResponse
        }
        return OAuthTokens(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken,
            expiresAt: Date().addingTimeInterval(decoded.expiresIn),
            scope: decoded.scope ?? fallbackScope
        )
    }

    /// A JSON POST shaped like the CLI's. The gateway rejects requests that don't carry the
    /// CLI's headers with a generic 429 (not a 400) — so these aren't optional. `x-app: cli`,
    /// the OAuth beta flag, the API version, and a `claude-cli` User-Agent together make the
    /// request look like the CLI's, which is the client we're reusing. Without them every
    /// exchange fails as a false "rate limit".
    private func cliRequest(url: URL, body: [String: String]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("cli", forHTTPHeaderField: "x-app")
        request.setValue("claude-cli/2.1.205 (external, cli)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Sends the request and hands back its body, turning anything that isn't a 2xx into
    /// `OAuthError.http` so callers can distinguish an auth rejection from a transport failure.
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OAuthError.http(-1) }
        guard (200..<300).contains(http.statusCode) else { throw OAuthError.http(http.statusCode) }
        return data
    }
}
