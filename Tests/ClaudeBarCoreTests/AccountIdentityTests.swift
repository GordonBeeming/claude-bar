import Foundation
import Testing
@testable import ClaudeBarCore

struct ProfileDecodeTests {
    @Test func readsEmailAndOrganisation() {
        let json = #"{"account":{"email":"a@b.com","uuid":"u"},"organization":{"name":"Org","uuid":"o"}}"#
        #expect(ProfileClient.decode(Data(json.utf8)) == ProfileIdentity(email: "a@b.com", organization: "Org"))
    }

    @Test func readsTheEmailAddressSpelling() {
        let json = #"{"account":{"email_address":"a@b.com"}}"#
        #expect(ProfileClient.decode(Data(json.utf8)) == ProfileIdentity(email: "a@b.com", organization: nil))
    }

    @Test func nilWhenNeitherIsPresentAndShapeListsKeysOnly() {
        let json = #"{"account":{"uuid":"secret-value"},"other":1}"#
        #expect(ProfileClient.decode(Data(json.utf8)) == nil)
        let shape = ProfileClient.shape(of: Data(json.utf8))
        #expect(shape == "account{uuid} other")
        #expect(!shape.contains("secret-value"))
    }

    @Test func malformedBodyIsNil() {
        #expect(ProfileClient.decode(Data("nope".utf8)) == nil)
    }
}

private actor Calls {
    private(set) var fetches: [String] = []
    private(set) var recorded: [ProfileIdentity] = []
    func fetched(_ token: String) { fetches.append(token) }
    func record(_ identity: ProfileIdentity) { recorded.append(identity) }
}

struct SelfContainedIdentityResolverTests {
    private func tokens(access: String = "at1", email: String? = nil) -> OAuthTokens {
        OAuthTokens(
            accessToken: access, refreshToken: "rt", expiresAt: Date().addingTimeInterval(3600),
            scope: OAuthConfig.scopes, accountEmail: email
        )
    }

    private func resolver(
        calls: Calls,
        tokens: @escaping @Sendable () -> OAuthTokens?,
        result: @escaping @Sendable () throws -> ProfileIdentity,
        recordResult: LockedBox<SelfContainedCredentialStore.RotatedSaveResult> = LockedBox(.saved),
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> SelfContainedIdentityResolver {
        SelfContainedIdentityResolver(
            currentTokens: { tokens() },
            fetch: { token in
                await calls.fetched(token)
                return try result()
            },
            record: { identity, _ in Task { await calls.record(identity) }; return recordResult.value },
            now: now
        )
    }

    @Test func storedIdentityIsUsedWithoutALookup() async {
        let calls = Calls()
        let resolver = resolver(calls: calls, tokens: { tokens(email: "stored@b.com") }, result: { throw ProfileClient.ProfileError.noIdentity })
        #expect(await resolver.identity()?.email == "stored@b.com")
        #expect(await calls.fetches.isEmpty)
    }

    @Test func lookupIsCachedPerAccessTokenAndRefetchedForANewOne() async {
        let calls = Calls()
        let current = LockedBox("at1")
        let resolver = resolver(
            calls: calls,
            tokens: { tokens(access: current.value) },
            result: { ProfileIdentity(email: "a@b.com", organization: "Org") }
        )

        #expect(await resolver.identity()?.email == "a@b.com")
        #expect(await resolver.identity()?.email == "a@b.com")
        #expect(await calls.fetches == ["at1"])

        current.value = "at2"
        #expect(await resolver.identity()?.email == "a@b.com")
        #expect(await calls.fetches == ["at1", "at2"])
    }

    @Test func aSuccessfulLookupIsWrittenBack() async throws {
        let calls = Calls()
        let resolver = resolver(calls: calls, tokens: { tokens() }, result: { ProfileIdentity(email: "a@b.com", organization: nil) })
        _ = await resolver.identity()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await calls.recorded == [ProfileIdentity(email: "a@b.com", organization: nil)])
    }

    @Test func aFailureLeavesNoIdentityAndBacksOffThenRetries() async {
        let calls = Calls()
        let clock = LockedBox(Date(timeIntervalSince1970: 1_000))
        let resolver = resolver(
            calls: calls,
            tokens: { tokens() },
            result: { throw ProfileClient.ProfileError.http(500) },
            now: { clock.value }
        )

        #expect(await resolver.identity() == nil)
        #expect(await resolver.identity() == nil)
        #expect(await calls.fetches.count == 1)

        clock.value = Date(timeIntervalSince1970: 1_000 + 601)
        #expect(await resolver.identity() == nil)
        #expect(await calls.fetches.count == 2)
    }

    @Test func aSupersededSignInDiscardsTheLookup() async {
        let calls = Calls()
        let resolver = resolver(
            calls: calls,
            tokens: { tokens() },
            result: { ProfileIdentity(email: "a@b.com", organization: nil) },
            recordResult: LockedBox(.superseded)
        )
        #expect(await resolver.identity() == nil)
    }

    @Test func noTokensMeansNoIdentity() async {
        let calls = Calls()
        let resolver = resolver(calls: calls, tokens: { nil }, result: { ProfileIdentity(email: "x", organization: nil) })
        #expect(await resolver.identity() == nil)
        #expect(await calls.fetches.isEmpty)
    }
}

final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

struct IdentityChangeDetectorTests {
    @Test func unchangedIsNone() {
        var detector = IdentityChangeDetector(source: "selfContained", email: "a@b.com")
        #expect(detector.observe(source: "selfContained", email: "a@b.com") == .none)
    }

    @Test func unknownBecomingKnownIsOnlyLabelling() {
        var detector = IdentityChangeDetector(source: "selfContained", email: nil)
        #expect(detector.observe(source: "selfContained", email: "a@b.com") == .labelled)
    }

    @Test func aDifferentEmailOrSourceIsReplaced() {
        var detector = IdentityChangeDetector(source: "selfContained", email: "a@b.com")
        #expect(detector.observe(source: "selfContained", email: "c@d.com") == .replaced)
        #expect(detector.observe(source: "claudeCode", email: "c@d.com") == .replaced)
        // Known becoming unknown is a change too; only the reverse is labelling.
        #expect(detector.observe(source: "claudeCode", email: nil) == .replaced)
        #expect(detector.observe(source: "claudeCode", email: "e@f.com") == .labelled)
    }

    @Test func aMovedRevisionIsADifferentSignInEvenWithTheSameOrNoEmail() {
        var detector = IdentityChangeDetector(source: "selfContained", email: nil, revision: 3)
        #expect(detector.noteRevision(3) == false)
        #expect(detector.noteRevision(4) == true)
        #expect(detector.noteRevision(4) == false)

        // Unknown on both sides would read as "labelling", so the swap is forced explicitly.
        detector.markReplaced()
        #expect(detector.observe(source: "selfContained", email: nil) == .replaced)
        #expect(detector.observe(source: "selfContained", email: nil) == .none)
    }

    @Test func unknownEmailOnAnotherSourceIsReplaced() {
        var detector = IdentityChangeDetector(source: "claudeCode", email: nil)
        #expect(detector.observe(source: "selfContained", email: "a@b.com") == .replaced)
    }
}

struct DiscoveryIDMergeTests {
    @Test func mergeNeverDropsOrChangesAReservation() {
        let current = ["/a": "work", "/b": "work-2"]
        let stale = ["/a": "other", "/c": "new"]
        let merged = ClaudeAccountDiscovery.mergeIDs(existing: current, new: stale)
        #expect(merged == ["/a": "work", "/b": "work-2", "/c": "new"])
        // A result that knows fewer paths cannot remove any.
        #expect(ClaudeAccountDiscovery.mergeIDs(existing: current, new: [:]) == current)
    }
}
