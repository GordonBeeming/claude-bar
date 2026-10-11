import Foundation

/// Claude Code guest passes: invites the account can hand out, each redeemable once.
public struct GuestPassStatus: Codable, Sendable, Equatable {
    public let campaign: String
    public let eligible: Bool
    /// Passes not yet redeemed. nil when the account isn't eligible.
    public let remaining: Int?
    public let limit: Int?
    public let rewardMinorUnits: Int64?
    public let rewardCurrency: String?

    public init(
        campaign: String,
        eligible: Bool,
        remaining: Int?,
        limit: Int?,
        rewardMinorUnits: Int64? = nil,
        rewardCurrency: String? = nil
    ) {
        self.campaign = campaign
        self.eligible = eligible
        self.remaining = remaining
        self.limit = limit
        self.rewardMinorUnits = rewardMinorUnits
        self.rewardCurrency = rewardCurrency
    }
}

/// A promotional extra-usage credit the account can claim.
public struct CreditGrantStatus: Codable, Sendable, Equatable {
    public let campaign: String
    public let available: Bool
    public let eligible: Bool
    public let granted: Bool
    public let amountMinorUnits: Int64?
    public let currency: String?

    public init(
        campaign: String,
        available: Bool,
        eligible: Bool,
        granted: Bool,
        amountMinorUnits: Int64? = nil,
        currency: String? = nil
    ) {
        self.campaign = campaign
        self.available = available
        self.eligible = eligible
        self.granted = granted
        self.amountMinorUnits = amountMinorUnits
        self.currency = currency
    }

    /// Offered and still claimable.
    public var isClaimable: Bool { available && eligible && !granted }
}

/// Redeemable things on the account. Each part is nil when its fetch failed, so one
/// unavailable endpoint doesn't hide the other.
public struct AccountOffers: Codable, Sendable, Equatable {
    public var guestPasses: GuestPassStatus?
    public var creditGrant: CreditGrantStatus?

    public init(guestPasses: GuestPassStatus? = nil, creditGrant: CreditGrantStatus? = nil) {
        self.guestPasses = guestPasses
        self.creditGrant = creditGrant
    }
}

/// Reads the account endpoints Claude Code uses for guest passes and promotional credit.
/// None of them is a documented public API, so every response is decoded leniently and
/// referral codes and links are never decoded at all: they're personal and have no place
/// in telemetry.
public struct AccountClient: Sendable {
    public enum AccountError: Error, Equatable {
        case unauthorized
        case http(Int)
        case noOrganization
    }

    static let guestPassCampaign = "claude_code_guest_pass"
    static let creditGrantCampaign = "feature_of_the_week"

    private static let base = URL(string: "https://api.anthropic.com")!

    public init() {}

    /// The organization the token belongs to, from the OAuth profile. Falls back to the
    /// organization Claude Code recorded in `~/.claude.json` if the profile call fails.
    public func organizationUUID(token: String) async throws -> String {
        struct Profile: Decodable {
            struct Organization: Decodable { let uuid: String? }
            let organization: Organization?
        }
        let profileError: Error?
        do {
            let profile = try await get(Profile.self, path: "/api/oauth/profile", token: token)
            if let uuid = profile.organization?.uuid, !uuid.isEmpty { return uuid }
            profileError = nil
        } catch AccountError.unauthorized {
            // A rejected token won't do any better against the org endpoints.
            throw AccountError.unauthorized
        } catch {
            profileError = error
        }
        if let uuid = Self.organizationUUIDFromClaudeConfig() { return uuid }
        throw profileError ?? AccountError.noOrganization
    }

    public func guestPasses(organization: String, token: String) async throws -> GuestPassStatus {
        let campaign = Self.guestPassCampaign
        let eligibility = try await get(
            Eligibility.self,
            path: "/api/oauth/organizations/\(organization)/referral/eligibility",
            query: [URLQueryItem(name: "campaign", value: campaign)],
            token: token
        )
        let reportedCampaign = eligibility.referralCodeDetails?.campaign ?? campaign
        guard eligibility.eligible == true else {
            return GuestPassStatus(campaign: reportedCampaign, eligible: false, remaining: nil, limit: eligibility.limit)
        }

        var remaining = eligibility.remainingPasses
        var limit = eligibility.limit
        if remaining == nil {
            // Older responses left the count out; the redemptions list fills it in.
            let redemptions = try await get(
                Redemptions.self,
                path: "/api/oauth/organizations/\(organization)/referral/redemptions",
                query: [URLQueryItem(name: "campaign", value: reportedCampaign)],
                token: token
            )
            let total = redemptions.limit ?? limit ?? 3
            limit = total
            remaining = max(total - (redemptions.redemptions?.count ?? 0), 0)
        }
        return GuestPassStatus(
            campaign: reportedCampaign,
            eligible: true,
            remaining: remaining,
            limit: limit,
            rewardMinorUnits: eligibility.referrerReward?.amountMinorUnits,
            rewardCurrency: eligibility.referrerReward?.currency
        )
    }

    public func creditGrant(organization: String, token: String) async throws -> CreditGrantStatus {
        let campaign = Self.creditGrantCampaign
        let grant = try await get(
            Grant.self,
            path: "/api/oauth/organizations/\(organization)/overage_credit_grant",
            query: [URLQueryItem(name: "campaign", value: campaign)],
            token: token
        )
        return CreditGrantStatus(
            campaign: campaign,
            available: grant.available ?? false,
            eligible: grant.eligible ?? false,
            granted: grant.granted ?? false,
            amountMinorUnits: grant.amountMinorUnits,
            currency: grant.currency
        )
    }

    static func organizationUUIDFromClaudeConfig(
        url: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json")
    ) -> String? {
        struct Config: Decodable {
            struct Account: Decodable { let organizationUuid: String? }
            let oauthAccount: Account?
        }
        guard let data = try? Data(contentsOf: url),
              let uuid = (try? JSONDecoder().decode(Config.self, from: data))?.oauthAccount?.organizationUuid,
              !uuid.isEmpty
        else {
            return nil
        }
        return uuid
    }

    // MARK: Wire shapes

    struct Eligibility: Decodable {
        struct Details: Decodable { let campaign: String? }
        struct Reward: Decodable {
            let amountMinorUnits: Int64?
            let currency: String?
            enum CodingKeys: String, CodingKey {
                case amountMinorUnits = "amount_minor_units"
                case currency
            }
        }

        let eligible: Bool?
        let remainingPasses: Int?
        let limit: Int?
        let referralCodeDetails: Details?
        let referrerReward: Reward?

        enum CodingKeys: String, CodingKey {
            case eligible, limit
            case remainingPasses = "remaining_passes"
            case referralCodeDetails = "referral_code_details"
            case referrerReward = "referrer_reward"
        }
    }

    struct Redemptions: Decodable {
        struct Ignored: Decodable {}
        let redemptions: [Ignored]?
        let limit: Int?
    }

    struct Grant: Decodable {
        let available: Bool?
        let eligible: Bool?
        let granted: Bool?
        let amountMinorUnits: Int64?
        let currency: String?

        enum CodingKeys: String, CodingKey {
            case available, eligible, granted, currency
            case amountMinorUnits = "amount_minor_units"
        }
    }

    private func get<T: Decodable>(
        _ type: T.Type,
        path: String,
        query: [URLQueryItem] = [],
        token: String
    ) async throws -> T {
        var components = URLComponents(url: Self.base.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw URLError(.badURL) }

        let (data, response) = try await URLSession.shared.data(for: UsageClient.authorizedGET(url, token: token))
        guard let http = response as? HTTPURLResponse else { throw AccountError.http(-1) }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw AccountError.unauthorized }
            throw AccountError.http(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
