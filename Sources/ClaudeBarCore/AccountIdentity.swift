import Foundation
import os

/// Who a token belongs to, as the OAuth profile endpoint reports it.
public struct ProfileIdentity: Sendable, Equatable {
    public let email: String?
    public let organization: String?

    public init(email: String?, organization: String?) {
        self.email = email
        self.organization = organization
    }
}

/// Decides when an account has become someone else, so everything cached for the old identity
/// (usage, celebration baselines, offers) is dropped and in-flight answers are ignored.
public struct IdentityChangeDetector: Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        case none
        /// An unknown email became known for the same source: the same sign-in being labelled.
        case labelled
        case replaced
    }

    private var source: String
    private var email: String?
    private var organization: String?
    private var revision: Int

    public init(source: String, email: String?, organization: String? = nil, revision: Int = 0) {
        self.source = source
        self.email = email
        self.organization = organization
        self.revision = revision
    }

    /// Records the current credential revision (bumped whenever the sign-in is saved or
    /// removed) and says whether it moved. A moved revision means a different sign-in, even
    /// when the email lookup for the new one fails or comes back the same.
    public mutating func noteRevision(_ newRevision: Int) -> Bool {
        defer { revision = newRevision }
        return newRevision != revision
    }

    /// Makes the next `observe` report `.replaced`, for a change `observe` can't see itself (the
    /// sign-in was swapped but the email reads the same, or is unknown on both sides).
    public mutating func markReplaced() {
        source = ""
        email = nil
        organization = nil
    }

    /// The organisation counts: the same email on another organisation has other limits and
    /// offers. It is only "labelling" when what was unknown becomes known.
    public mutating func observe(source newSource: String, email newEmail: String?, organization newOrganization: String? = nil) -> Change {
        guard newSource != source || newEmail != email || newOrganization != organization else { return .none }
        let labelling = newSource == source && (email == nil || (newEmail == email && organization == nil))
        source = newSource
        email = newEmail
        organization = newOrganization
        return labelling ? .labelled : .replaced
    }
}

/// Reads `GET /api/oauth/profile`, which the `user:profile` scope already covers.
public struct ProfileClient: Sendable {
    public enum ProfileError: Error, Equatable {
        case unauthorized
        case http(Int)
        /// A 2xx body with neither an email nor an organization name in it.
        case noIdentity
    }

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    private static let logger = Logger(subsystem: "com.gordonbeeming.ClaudeBar", category: "ProfileClient")

    public init() {}

    public func identity(token: String) async throws -> ProfileIdentity {
        let (data, response) = try await URLSession.shared.data(for: UsageClient.authorizedGET(Self.endpoint, token: token))
        guard let http = response as? HTTPURLResponse else { throw ProfileError.http(-1) }
        guard (200..<300).contains(http.statusCode) else {
            throw http.statusCode == 401 ? ProfileError.unauthorized : ProfileError.http(http.statusCode)
        }
        guard let identity = Self.decode(data) else {
            // Keys only: the values are personal.
            Self.logger.error("profile response had no email or organization; shape: \(Self.shape(of: data), privacy: .public)")
            throw ProfileError.noIdentity
        }
        return identity
    }

    /// Both spellings of the email field are accepted, since the endpoint isn't documented.
    /// Nil when neither the email nor the organization name is present.
    static func decode(_ data: Data) -> ProfileIdentity? {
        struct Body: Decodable {
            struct Account: Decodable {
                let email: String?
                let emailAddress: String?
                private enum CodingKeys: String, CodingKey {
                    case email
                    case emailAddress = "email_address"
                }
            }
            struct Organization: Decodable { let name: String? }
            let account: Account?
            let organization: Organization?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return nil }
        func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
        let email = nonEmpty(body.account?.email) ?? nonEmpty(body.account?.emailAddress)
        let organization = nonEmpty(body.organization?.name)
        guard email != nil || organization != nil else { return nil }
        return ProfileIdentity(email: email, organization: organization)
    }

    static func shape(of data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "not a JSON object" }
        return object.keys.sorted().map { key in
            if let nested = object[key] as? [String: Any] {
                return "\(key){\(nested.keys.sorted().joined(separator: ","))}"
            }
            return key
        }.joined(separator: " ")
    }
}

/// Works out who a self-contained sign-in belongs to when the stored tokens don't say (items
/// saved before the identity was recorded). Best effort by design: a failure is logged, the
/// caller keeps the folder-name label, and nobody is signed out.
public actor SelfContainedIdentityResolver {
    private static let logger = Logger(subsystem: "com.gordonbeeming.ClaudeBar", category: "AccountIdentity")
    /// How long a failed lookup is left alone, so a poll every minute doesn't hammer the endpoint.
    private static let retryAfterFailure: TimeInterval = 600

    private let currentTokens: @Sendable () async -> OAuthTokens?
    private let fetch: @Sendable (String) async throws -> ProfileIdentity
    private let record: @Sendable (ProfileIdentity, OAuthTokens) -> SelfContainedCredentialStore.RotatedSaveResult
    private let now: @Sendable () -> Date
    private var resolved: (accessToken: String, identity: ProfileIdentity)?
    private var failed: (accessToken: String, at: Date)?

    init(
        currentTokens: @escaping @Sendable () async -> OAuthTokens?,
        fetch: @escaping @Sendable (String) async throws -> ProfileIdentity,
        record: @escaping @Sendable (ProfileIdentity, OAuthTokens) -> SelfContainedCredentialStore.RotatedSaveResult,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.currentTokens = currentTokens
        self.fetch = fetch
        self.record = record
        self.now = now
    }

    /// `service` supplies the tokens so the identity lookup shares the account's single-flight
    /// refresh instead of refreshing on its own.
    public init(account: ClaudeAccount, service: UsageService, client: ProfileClient = ProfileClient()) {
        let store = SelfContainedCredentialStore(account: account)
        self.init(
            currentTokens: { await service.selfContainedTokens() },
            fetch: { try await client.identity(token: $0) },
            record: { identity, tokens in store.recordIdentity(identity, replacing: tokens) }
        )
    }

    public func identity() async -> ProfileIdentity? {
        guard let tokens = await currentTokens() else { return nil }
        if tokens.accountEmail != nil || tokens.organizationName != nil {
            return ProfileIdentity(email: tokens.accountEmail, organization: tokens.organizationName)
        }
        if let resolved, resolved.accessToken == tokens.accessToken { return resolved.identity }
        if let failed, failed.accessToken == tokens.accessToken, now().timeIntervalSince(failed.at) < Self.retryAfterFailure {
            return nil
        }
        do {
            let identity = try await fetch(tokens.accessToken)
            resolved = (tokens.accessToken, identity)
            failed = nil
            // The compare-and-swap is what says the sign-in looked up is still the stored one.
            // If it was signed out or replaced meanwhile, this answer is about someone else.
            if record(identity, tokens) == .superseded {
                resolved = nil
                Self.logger.notice("identity lookup discarded: the sign-in changed meanwhile")
                return nil
            }
            Self.logger.notice("identity lookup succeeded")
            return identity
        } catch {
            failed = (tokens.accessToken, now())
            Self.logger.error("identity lookup failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
