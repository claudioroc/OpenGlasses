import Foundation
import CryptoKit

/// Pure core for the Anthropic "Sign in with Claude" OAuth flow (Plan-style deterministic core —
/// no I/O, fully unit-testable). The network/persistence edge lives in `ClaudeOAuthService`.
///
/// Flow (authorization code + PKCE, same protocol the official `ant auth login` CLI uses):
/// 1. Build an authorize URL with a fresh PKCE verifier and open it in the browser.
/// 2. The user signs in with their claude.ai account; the callback page displays an
///    authorization code (`code#state`) which they copy and paste back into the app.
/// 3. Exchange the code for an access token (`sk-ant-oat…`) + refresh token at the token endpoint.
/// 4. API calls authenticate with `Authorization: Bearer` + the `oauth-2025-04-20` beta header
///    instead of `x-api-key`.
enum ClaudeOAuth {

    // MARK: - Protocol constants

    /// Anthropic's public OAuth client (the one issued for CLI/desktop sign-in).
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeEndpoint = "https://claude.ai/oauth/authorize"
    static let tokenEndpoint = "https://console.anthropic.com/v1/oauth/token"
    /// Redirect target registered for the public client — a page that displays the code to paste.
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let scopes = "org:create_api_key user:profile user:inference"
    /// Beta header required when authenticating `/v1/messages` (and friends) with an OAuth token.
    static let oauthBetaHeader = "oauth-2025-04-20"

    /// OAuth access tokens are distinguishable from API keys by prefix
    /// (`sk-ant-oat…` vs `sk-ant-api…`).
    static func isOAuthToken(_ credential: String) -> Bool {
        credential.hasPrefix("sk-ant-oat")
    }

    // MARK: - PKCE

    /// Base64url (no padding) — the encoding PKCE uses for both verifier and challenge.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Derive a code verifier from random bytes (injectable so tests are deterministic).
    static func verifier(from randomBytes: Data) -> String {
        base64URL(randomBytes)
    }

    /// Generate a fresh random verifier (32 random bytes → 43-char base64url string).
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return verifier(from: Data(bytes))
    }

    /// S256 code challenge for a verifier (RFC 7636).
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    // MARK: - Authorize URL

    /// Build the browser authorize URL. `state` doubles as CSRF token; the token exchange
    /// sends it back alongside the code.
    static func authorizeURL(verifier: String, state: String) -> URL? {
        var components = URLComponents(string: authorizeEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components?.url
    }

    // MARK: - Pasted-code parsing

    /// The callback page shows the authorization code as `code#state`. Accept that, a bare
    /// code, or a full callback URL the user pasted; trim whitespace either way.
    static func parseAuthorizationInput(_ input: String) -> (code: String, state: String?)? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // Full callback URL pasted: pull code/state from the query.
        if text.hasPrefix("http"), let components = URLComponents(string: text) {
            let code = components.queryItems?.first(where: { $0.name == "code" })?.value
            let state = components.queryItems?.first(where: { $0.name == "state" })?.value
            if let code, !code.isEmpty { return (code, state) }
            if let fragment = components.fragment { text = fragment } else { return nil }
        }
        let parts = text.split(separator: "#", maxSplits: 1).map(String.init)
        guard let code = parts.first, !code.isEmpty else { return nil }
        return (code, parts.count > 1 ? parts[1] : nil)
    }

    // MARK: - Token requests

    static func tokenExchangeRequest(code: String, state: String?, verifier: String) -> URLRequest {
        var body: [String: Any] = [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ]
        if let state { body["state"] = state }
        return jsonPOST(body: body)
    }

    static func refreshRequest(refreshToken: String) -> URLRequest {
        jsonPOST(body: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
    }

    private static func jsonPOST(body: [String: Any]) -> URLRequest {
        var request = URLRequest(url: URL(string: tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30
        return request
    }

    // MARK: - Token response / credentials

    struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    struct Credentials: Codable, Equatable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?

        init(response: TokenResponse, now: Date = Date(), previousRefreshToken: String? = nil) {
            accessToken = response.accessToken
            // A refresh response may omit the refresh token — keep the old one.
            refreshToken = response.refreshToken ?? previousRefreshToken
            expiresAt = response.expiresIn.map { now.addingTimeInterval($0) }
        }

        /// Refresh ahead of expiry so an in-flight request doesn't race the deadline.
        func needsRefresh(now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
            guard let expiresAt else { return false }
            return now.addingTimeInterval(leeway) >= expiresAt
        }
    }
}

/// Applies Anthropic authentication to a request: OAuth access tokens (`sk-ant-oat…`) go on
/// `Authorization: Bearer` with the OAuth beta header; anything else is a regular API key on
/// `x-api-key`. Pure — credential resolution (refresh, keychain) happens in `ClaudeOAuthService`.
enum AnthropicAuth {
    static func apply(credential: String, to request: inout URLRequest) {
        if ClaudeOAuth.isOAuthToken(credential) {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            request.setValue(ClaudeOAuth.oauthBetaHeader, forHTTPHeaderField: "anthropic-beta")
        } else {
            request.setValue(credential, forHTTPHeaderField: "x-api-key")
        }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    }

    /// Anthropic Messages API credentials belong to the configured model. Do not silently borrow
    /// a Claude.ai/Claude Code session: those credentials are not an app API key and make the UI
    /// report a successful sign-in while requests fail later at the provider.
    static func resolveCredential(apiKey: String) -> String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
