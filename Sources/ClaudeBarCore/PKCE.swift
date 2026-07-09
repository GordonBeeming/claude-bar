import CryptoKit
import Foundation

/// A PKCE (RFC 7636) verifier/challenge pair for the OAuth authorization-code flow.
/// The `verifier` is kept locally and sent on the token exchange; the `challenge` goes in
/// the authorize URL, so an intercepted authorization code can't be redeemed without the
/// verifier.
public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String

    /// Generates a fresh pair from 32 random bytes. `SystemRandomNumberGenerator` is a CSPRNG
    /// on Apple platforms, which is what PKCE requires.
    public init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        var rng = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = rng.next() }
        let verifier = Data(bytes).base64URLEncodedString()
        self.verifier = verifier

        let digest = SHA256.hash(data: Data(verifier.utf8))
        self.challenge = Data(digest).base64URLEncodedString()
    }
}

extension Data {
    /// base64url without padding, per RFC 7636 §4.1 — the encoding OAuth PKCE expects.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
