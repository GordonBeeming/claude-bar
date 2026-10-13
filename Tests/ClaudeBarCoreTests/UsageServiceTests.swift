import Foundation
import Testing
@testable import ClaudeBarCore

/// Records what the service touched, so a test can prove Claude Code's Keychain item was
/// never read in self-contained mode: that read is what puts up the consent prompt.
private actor Probe {
    private(set) var claudeCodeReads = 0
    private(set) var clearedTokens: [String] = []
    private(set) var selfContainedReads = 0
    private(set) var usageTokens: [String] = []

    func readClaudeCode() { claudeCodeReads += 1 }
    func clear(_ token: String) { clearedTokens.append(token) }
    private var issued = 0
    /// Hands out each token in turn, so a test can play a sign-in replacing the first.
    func nextToken(from tokens: [String]) -> String? {
        defer { issued += 1 }
        return issued < tokens.count ? tokens[issued] : tokens.last
    }
    func readSelfContained() { selfContainedReads += 1 }
    func fetched(with token: String) { usageTokens.append(token) }
}

struct UsageServiceTests {
    private static func service(
        _ probe: Probe,
        selfContained: @escaping @Sendable () async throws -> String?,
        claudeCode: String? = "claude-code-token",
        clearSucceeds: @escaping @Sendable (String) -> Bool = { _ in true },
        usage: @escaping @Sendable (String) async throws -> UsageResponse = { _ in UsageResponse(limits: []) }
    ) -> UsageService {
        UsageService(
            selfContainedToken: {
                await probe.readSelfContained()
                return try await selfContained()
            },
            claudeCodeToken: {
                await probe.readClaudeCode()
                return claudeCode
            },
            clearSelfContained: { token in
                await probe.clear(token)
                return clearSucceeds(token)
            },
            fetchUsage: { token in
                await probe.fetched(with: token)
                return try await usage(token)
            }
        )
    }

    @Test("Self-contained mode uses its own token and never reads Claude Code's")
    func selfContainedUsesOwnToken() async throws {
        let probe = Probe()
        let service = Self.service(probe, selfContained: { "own-token" })

        _ = try await service.fetch(preferSelfContained: true)

        #expect(await probe.usageTokens == ["own-token"])
        #expect(await probe.claudeCodeReads == 0)
    }

    @Test("Signed out in self-contained mode is reported as signed out, without a Keychain prompt")
    func signedOutDoesNotFallBack() async {
        let probe = Probe()
        let service = Self.service(probe, selfContained: { nil })

        await #expect(throws: UsageClient.UsageError.signedOut) {
            try await service.fetch(preferSelfContained: true)
        }
        #expect(await probe.claudeCodeReads == 0)
        #expect(await probe.usageTokens.isEmpty)
    }

    @Test("A token the usage API rejects is cleared, by that token, and reads as signed out")
    func rejectedTokenSignsOut() async {
        let probe = Probe()
        let service = Self.service(
            probe,
            selfContained: { "own-token" },
            usage: { _ in throw UsageClient.UsageError.unauthorized }
        )

        await #expect(throws: UsageClient.UsageError.signedOut) {
            try await service.fetch(preferSelfContained: true)
        }
        // Only the rejected token is named, so a sign-in that landed meanwhile survives.
        #expect(await probe.clearedTokens == ["own-token"])
        #expect(await probe.claudeCodeReads == 0)
    }

    @Test("A 401 on a token a newer sign-in replaced retries with the newer one")
    func rejectedTokenReplacedRetries() async throws {
        let probe = Probe()
        let service = Self.service(
            probe,
            selfContained: { await probe.nextToken(from: ["old-token", "new-token"]) },
            clearSucceeds: { _ in false },
            usage: { token in
                guard token == "new-token" else { throw UsageClient.UsageError.unauthorized }
                return UsageResponse(limits: [])
            }
        )

        _ = try await service.fetch(preferSelfContained: true)

        #expect(await probe.usageTokens == ["old-token", "new-token"])
        #expect(await probe.claudeCodeReads == 0)
    }

    @Test("A refresh rejected as expired or revoked reads as signed out", arguments: [400, 401])
    func rejectedRefreshSignsOut(status: Int) async {
        let probe = Probe()
        let service = Self.service(probe, selfContained: {
            throw SelfContainedCredentialStore.StoreError.grantRejected(status: status)
        })

        await #expect(throws: UsageClient.UsageError.signedOut) {
            try await service.fetch(preferSelfContained: true)
        }
        // The store already cleared the exact pair it refreshed; the service mustn't clear again.
        #expect(await probe.clearedTokens.isEmpty)
        #expect(await probe.claudeCodeReads == 0)
    }

    @Test("A network or server error keeps the sign-in and fails only this poll")
    func transientErrorKeepsSignIn() async {
        let probe = Probe()
        let service = Self.service(probe, selfContained: { throw OAuthClient.OAuthError.http(503) })

        await #expect(throws: OAuthClient.OAuthError.http(503)) {
            try await service.fetch(preferSelfContained: true)
        }
        #expect(await probe.clearedTokens.isEmpty)
        #expect(await probe.claudeCodeReads == 0)
    }

    @Test("An unreadable Keychain fails the poll without signing out")
    func unreadableKeychainIsNotSignedOut() async {
        let probe = Probe()
        let service = Self.service(probe, selfContained: {
            throw SelfContainedCredentialStore.StoreError.keychainUnavailable(status: Int(errSecInteractionNotAllowed))
        })

        await #expect(throws: SelfContainedCredentialStore.StoreError.keychainUnavailable(status: Int(errSecInteractionNotAllowed))) {
            try await service.fetch(preferSelfContained: true)
        }
        #expect(await probe.clearedTokens.isEmpty)
        #expect(await probe.claudeCodeReads == 0)
    }

    @Test("Claude Code mode still reads Claude Code's token")
    func claudeCodeModeUnchanged() async throws {
        let probe = Probe()
        let service = Self.service(probe, selfContained: { "own-token" })

        _ = try await service.fetch(preferSelfContained: false)

        #expect(await probe.usageTokens == ["claude-code-token"])
        #expect(await probe.selfContainedReads == 0)
    }

    @Test("Account offers in self-contained mode never fall back to Claude Code's token")
    func offersDoNotFallBack() async {
        let probe = Probe()
        let service = Self.service(probe, selfContained: {
            throw SelfContainedCredentialStore.StoreError.grantRejected(status: 400)
        })

        let offers = await service.fetchAccountOffers(preferSelfContained: true)

        #expect(offers == AccountOffers())
        #expect(await probe.claudeCodeReads == 0)
    }
}

/// Counts how many times the shared work actually ran.
private actor Counter {
    private(set) var runs = 0
    func next() -> Int {
        runs += 1
        return runs
    }
}

struct SingleFlightTests {
    @Test("Concurrent callers share one run, so a single-use refresh token is spent once")
    func concurrentCallersShareOneRun() async throws {
        let counter = Counter()
        let flight = SingleFlight<Int>()
        let work: @Sendable () async throws -> Int = {
            try await Task.sleep(for: .milliseconds(100))
            return await counter.next()
        }

        async let first = flight.run(work)
        async let second = flight.run(work)
        let results = try await [first, second]

        #expect(results == [1, 1])
        #expect(await counter.runs == 1)
    }

    @Test("Once a run has finished, the next call starts a fresh one")
    func laterCallRunsAgain() async throws {
        let counter = Counter()
        let flight = SingleFlight<Int>()
        let work: @Sendable () async throws -> Int = { await counter.next() }

        #expect(try await flight.run(work) == 1)
        #expect(try await flight.run(work) == 2)
    }

    @Test("A failed run is shared by everyone waiting on it, then forgotten")
    func failureIsSharedThenCleared() async throws {
        struct Boom: Error {}
        let counter = Counter()
        let flight = SingleFlight<Int>()
        let failing: @Sendable () async throws -> Int = {
            _ = await counter.next()
            try await Task.sleep(for: .milliseconds(100))
            throw Boom()
        }

        let caller: @Sendable () async -> Error? = {
            do {
                _ = try await flight.run(failing)
                return nil
            } catch {
                return error
            }
        }
        async let first = caller()
        async let second = caller()
        let errors = await [first, second]

        #expect(errors.allSatisfy { $0 is Boom })
        #expect(await counter.runs == 1)
        #expect(try await flight.run { 7 } == 7)
    }
}
