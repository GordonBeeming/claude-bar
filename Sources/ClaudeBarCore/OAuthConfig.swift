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

    /// The only scope the usage endpoint needs — verified against the live endpoints, not read
    /// off the CLI. With `user:profile` alone, exchange/usage/refresh all return 200 with a
    /// populated `limits`, and the server echoes the scope back rather than widening the grant
    /// to this client's registered set. The old value mirrored the CLI's; its
    /// `org:create_api_key` let this Keychain item mint organization API keys, to render a
    /// percentage. Don't widen without re-testing live.
    public static let scopes = "user:profile"

    /// Revoking here actually retires a grant. Deleting our Keychain item only drops our copy.
    public static let revokeURL = URL(string: "https://platform.claude.com/v1/oauth/token/revoke")!
}
