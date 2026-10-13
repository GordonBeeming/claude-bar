import Foundation
import Testing
@testable import ClaudeBarCore

/// Records what the service touched, so a test can prove Claude Code's Keychain item was
/// never read in self-contained mode: that read is what puts up the consent prompt.
private actor Probe {
    private(set) var claudeCodeReads = 0
    private(set) var clears = 0
    private(set) var selfContainedReads = 0
    private(set) var usageTokens: [String] = []

    func readClaudeCode() { claudeCodeReads += 1 }
    func clear() { clears += 1 }
    func readSelfContained() { selfContainedReads += 1 }
    func fetched(with token: String) { usageTokens.append(token) }
}

struct UsageServiceTests {
    private static func service(
        _ probe: Probe,
        selfContained: @escaping @Sendable () async throws -> String?,
        claudeCode: String? = "claude-code-token",
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
            clearSelfContained: { await probe.clear() },
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

    @Test("A token the usage API rejects is cleared and reads as signed out")
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
        #expect(await probe.clears == 1)
        #expect(await probe.claudeCodeReads == 0)
    }

    @Test("A refresh rejected as expired or revoked is cleared and reads as signed out", arguments: [400, 401])
    func rejectedRefreshSignsOut(status: Int) async {
        let probe = Probe()
        let service = Self.service(probe, selfContained: { throw OAuthClient.OAuthError.http(status) })

        await #expect(throws: UsageClient.UsageError.signedOut) {
            try await service.fetch(preferSelfContained: true)
        }
        #expect(await probe.clears == 1)
        #expect(await probe.claudeCodeReads == 0)
    }

    @Test("A network or server error keeps the sign-in and fails only this poll")
    func transientErrorKeepsSignIn() async {
        let probe = Probe()
        let service = Self.service(probe, selfContained: { throw OAuthClient.OAuthError.http(503) })

        await #expect(throws: OAuthClient.OAuthError.http(503)) {
            try await service.fetch(preferSelfContained: true)
        }
        #expect(await probe.clears == 0)
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
        let service = Self.service(probe, selfContained: { throw OAuthClient.OAuthError.http(400) })

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
        let flight = SingleFlight<Int>()

        await #expect(throws: Boom.self) {
            try await flight.run { throw Boom() }
        }
        #expect(try await flight.run { 7 } == 7)
    }
}
