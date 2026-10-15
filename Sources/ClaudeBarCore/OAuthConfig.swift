import Foundation

/// OAuth endpoints and client for a self-contained sign-in. These are Claude Code's own
/// public OAuth client values (confirmed from the CLI binary): the app signs in *as*
/// Claude Code — the same posture as the `claude-code` User-Agent the usage client sends.
/// Reusing them is unofficial and could break if Anthropic changes the flow; the caller
/// always keeps the read-the-CLI-token path as a fallback.
public enum OAuthConfig {
    /// Claude Code's public OAuth client id.
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// Subscription (claude.ai / Max) authorize page. `code=true` makes the callback page
    /// render the authorization code for the user to copy back — the manual-code flow the
    /// CLI uses, so no loopback redirect server is needed.
    public static let authorizeURL = URL(string: "https://claude.com/cai/oauth/authorize")!

    /// Token exchange + refresh endpoint.
    public static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

    /// The redirect the client is registered against; its page displays the code to paste.
    public static let redirectURI = "https://platform.claude.com/oauth/code/callback"

    /// What the usage endpoint needs. `user:profile` alone was enough when it was tested, then
    /// the endpoint started refusing it while the CLI's grant, which also carries
    /// `user:inference`, kept getting 200. `org:create_api_key` stays out: it would let this
    /// Keychain item mint organization API keys, to render a percentage. Don't change without
    /// testing the usage endpoint live.
    public static let scopes = "user:profile user:inference"

    /// Revoking here actually retires a grant. Deleting our Keychain item only drops our copy.
    public static let revokeURL = URL(string: "https://platform.claude.com/v1/oauth/token/revoke")!
}
