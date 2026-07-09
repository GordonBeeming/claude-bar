import AppKit
import ClaudeBarCore
import Foundation
import Observation
import os

/// Drives the manual-code OAuth sign-in from Settings: open the browser to the authorize
/// page, let the user paste back the code the callback page shows, exchange it for our own
/// token pair, and store it. Mirrors how the Claude Code CLI's `/login` works, so the
/// redirect is already allow-listed for the client we reuse.
@MainActor
@Observable
final class OAuthLoginController {
    enum Phase: Equatable {
        case signedOut
        /// Browser opened; waiting for the user to paste the code.
        case awaitingCode
        case exchanging
        case signedIn(expiresAt: Date)
        case failed(String)
    }

    private(set) var phase: Phase
    /// PKCE verifier + `state` held between opening the browser and the paste. Cleared once
    /// the exchange succeeds so a stale code can't be replayed.
    @ObservationIgnored private var pending: (pkce: PKCE, state: String)?

    private let store = SelfContainedCredentialStore()
    private let client = OAuthClient()
    private let logger = Logger(subsystem: "com.gordonbeeming.ClaudeBar", category: "OAuthLogin")

    init() {
        if let tokens = store.load() {
            phase = .signedIn(expiresAt: tokens.expiresAt)
        } else {
            phase = .signedOut
        }
    }

    var isSignedIn: Bool {
        if case .signedIn = phase { return true }
        return false
    }

    /// True while a browser flow is mid-air (PKCE + state retained), so a failed exchange —
    /// e.g. a transient 429 — can be retried by pasting a fresh code without reopening the
    /// browser. Cleared once sign-in succeeds or the user starts over.
    var hasPendingSignIn: Bool { pending != nil }

    /// Generates a fresh PKCE pair + state and opens the authorize page in the default
    /// browser. The user copies the code the callback renders and pastes it into Settings.
    func startSignIn() {
        let pkce = PKCE()
        let state = UUID().uuidString
        pending = (pkce, state)
        let url = OAuthClient.authorizeURL(challenge: pkce.challenge, state: state)
        NSWorkspace.shared.open(url)
        phase = .awaitingCode
    }

    func submitCode(_ pasted: String) async {
        guard let pending else {
            phase = .failed("Start sign-in first, then paste the code.")
            return
        }
        phase = .exchanging
        do {
            let code = try OAuthClient.parseCallbackCode(pasted, expectedState: pending.state)
            let tokens = try await client.exchange(code: code, verifier: pending.pkce.verifier, state: pending.state)
            guard store.save(tokens) else {
                phase = .failed("Signed in, but couldn't save the token to the Keychain.")
                return
            }
            self.pending = nil
            phase = .signedIn(expiresAt: tokens.expiresAt)
            logger.notice("self-contained sign-in succeeded")
        } catch {
            phase = .failed(Self.message(for: error))
            logger.error("self-contained sign-in failed: \(String(describing: error), privacy: .public)")
        }
    }

    func signOut() {
        store.clear()
        pending = nil
        phase = .signedOut
    }

    private static func message(for error: Error) -> String {
        switch error {
        case OAuthClient.OAuthError.stateMismatch:
            return "Security check failed (state mismatch). Start sign-in again."
        case OAuthClient.OAuthError.malformedResponse:
            return "Unexpected response from Anthropic. Try again."
        case OAuthClient.OAuthError.http(429):
            return "Anthropic is rate-limiting sign-in right now. Wait a minute, then Try again."
        case OAuthClient.OAuthError.http(400):
            return "That code didn't take (expired or already used). Try again for a fresh one."
        case OAuthClient.OAuthError.http(let status):
            return "Sign-in failed (HTTP \(status)). Try again for a fresh code."
        default:
            return "Sign-in failed: \(error.localizedDescription)"
        }
    }
}
