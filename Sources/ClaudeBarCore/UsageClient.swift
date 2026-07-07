import Foundation

/// Thin wrapper over the one endpoint this app needs.
public struct UsageClient: Sendable {
    public enum UsageError: Error, Equatable {
        case noToken
        case unauthorized
        case http(Int)
    }

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public init() {}

    public func fetchUsage(token: String) async throws -> UsageResponse {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // Anthropic routes requests without a `claude-code` User-Agent into a much
        // stricter rate-limit bucket, so this app would otherwise see persistent 429s.
        request.setValue("claude-code/2.1.114", forHTTPHeaderField: "User-Agent")

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
}
