import Foundation

/// Thin wrapper over the one endpoint this app needs.
public struct UsageClient: Sendable {
    public enum UsageError: Error, Equatable {
        case noToken
        case unauthorized
        /// Self-contained mode with no usable sign-in of our own. Kept apart from `noToken`
        /// because the fix is signing in again in Settings, not anything in Claude Code.
        case signedOut
        case http(Int)
    }

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public init() {}

    public func fetchUsage(token: String) async throws -> UsageResponse {
        let request = Self.authorizedGET(Self.endpoint, token: token)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageError.http(-1)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw UsageError.unauthorized
            }
            throw UsageError.http(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(UsageResponse.self, from: data)
    }

    /// The headers every OAuth-authenticated `api.anthropic.com` call from this app needs.
    static func authorizedGET(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // Anthropic routes requests without a `claude-code` User-Agent into a much
        // stricter rate-limit bucket, so this app would otherwise see persistent 429s.
        request.setValue("claude-code/2.1.114", forHTTPHeaderField: "User-Agent")
        return request
    }
}

/// Without this the menu and the log only say "The operation couldn't be completed", which
/// hides the status that says what actually went wrong.
extension UsageClient.UsageError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noToken: return "Claude Code credentials not found"
        case .unauthorized: return "Anthropic rejected the token (HTTP 401)"
        case .signedOut: return "Signed out"
        case .http(-1): return "No HTTP response from Anthropic"
        case .http(let status): return "Anthropic answered HTTP \(status)"
        }
    }
}
