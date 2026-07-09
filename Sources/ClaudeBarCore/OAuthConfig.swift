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

    /// Scopes Claude Code requests. `user:profile` / `user:inference` are what the usage
    /// endpoint needs; the full set mirrors the CLI so the grant looks identical.
    public static let scopes = "org:create_api_key user:profile user:inference"
}
