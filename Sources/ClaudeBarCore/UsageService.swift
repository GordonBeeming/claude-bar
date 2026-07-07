import Foundation

/// The credentials + network boundary as a single actor, so the view-model can just
/// `await fetch()` without worrying about Keychain access happening off-main.
public actor UsageService {
    private let credentialsProvider = CredentialsProvider()
    private let client = UsageClient()

    public init() {}

    public func fetch() async throws -> UsageResponse {
        guard let token = credentialsProvider.loadAccessToken() else {
            throw UsageClient.UsageError.noToken
        }
        return try await client.fetchUsage(token: token)
    }
}
