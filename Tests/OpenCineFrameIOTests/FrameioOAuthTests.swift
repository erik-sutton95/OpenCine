import Foundation
import Testing

@testable import OpenCineFrameIO

private let config = FrameioConfiguration(
    clientID: "test-client-id",
    redirectURI: "adobe+abc123://adobeid/test-client-id")

#if canImport(CryptoKit)
@Test func pkceChallengeMatchesRFC7636Vector() {
    // RFC 7636 Appendix B test vector for S256.
    let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
}

@Test func generatedVerifierIsValidLengthAndCharset() {
    let pkce = PKCE.generate()
    #expect(pkce.verifier.count >= 43 && pkce.verifier.count <= 128)
    // base64url alphabet only: no '+', '/', or '=' padding.
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    #expect(pkce.verifier.allSatisfy { allowed.contains($0) })
    #expect(pkce.challenge == PKCE.challenge(for: pkce.verifier))
}

@Test func authorizeURLCarriesPKCEAndOAuthParams() throws {
    let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    let url = FrameioOAuth.authorizeURL(config: config, pkce: pkce, state: "xyz")
    let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = Dictionary(
        uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(comps.host == "ims-na1.adobelogin.com")
    #expect(comps.path == "/ims/authorize/v2")
    #expect(items["client_id"] == "test-client-id")
    #expect(items["redirect_uri"] == "adobe+abc123://adobeid/test-client-id")
    #expect(items["response_type"] == "code")
    #expect(items["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    #expect(items["code_challenge_method"] == "S256")
    #expect(items["state"] == "xyz")
    #expect(items["scope"]?.isEmpty == false)
}
#endif

// Token requests are transport-neutral, so they are planned (and tested) on every platform.
@Test func tokenExchangeRequestIsFormPost() throws {
    let req = FrameioOAuth.tokenExchangeRequest(
        config: config, code: "auth-code", verifier: "v123")
    #expect(req.method == .post)
    #expect(
        req.url.absoluteString
            == "https://ims-na1.adobelogin.com/ims/token/v3?client_id=test-client-id")
    #expect(req.headers["Content-Type"] == "application/x-www-form-urlencoded")
    let body = String(decoding: req.body ?? Data(), as: UTF8.self)
    #expect(
        body
            == "grant_type=authorization_code&client_id=test-client-id&code=auth-code"
            + "&code_verifier=v123&redirect_uri=adobe%2Babc123%3A%2F%2Fadobeid%2Ftest-client-id")
}

@Test func refreshRequestUsesRefreshGrant() throws {
    let req = FrameioOAuth.refreshRequest(config: config, refreshToken: "r456")
    let body = String(decoding: req.body ?? Data(), as: UTF8.self)
    #expect(body == "grant_type=refresh_token&client_id=test-client-id&refresh_token=r456")
    #expect(req.headers["Authorization"] == nil)
}

@Test func injectedDigestDrivesTheChallenge() {
    // A non-Apple build passes its own SHA-256; the challenge is base64url of whatever it returns.
    let pkce = PKCE(verifier: "v", sha256: { _ in Data([0xFB, 0xFF]) })
    #expect(pkce.challenge == "-_8")
}

@Test func urlSchemeExtractsAdobeNativeAppRedirect() {
    let uri = "adobe+abc123://adobeid/727e9081b73a46b286d6f491ed0ff602"
    #expect(FrameioOAuth.urlScheme(from: uri) == "adobe+abc123")
}

@Test func parseRedirectExtractsCodeAndValidatesState() throws {
    let url = URL(string: "adobe+abc123://adobeid/test-client-id?code=abc123&state=xyz")!
    let code = try FrameioOAuth.parseRedirect(url, expectedState: "xyz")
    #expect(code == "abc123")
}

@Test func parseRedirectRejectsStateMismatchAndErrors() {
    let mismatch = URL(string: "adobe+abc123://adobeid/test-client-id?code=abc&state=nope")!
    #expect(throws: FrameioOAuthError.stateMismatch) {
        try FrameioOAuth.parseRedirect(mismatch, expectedState: "xyz")
    }
    let denied = URL(string: "adobe+abc123://adobeid/test-client-id?error=access_denied")!
    #expect(throws: (any Error).self) {
        try FrameioOAuth.parseRedirect(denied, expectedState: "xyz")
    }
}

@Test func tokenDecodesFromIMSResponse() throws {
    let json = """
        { "access_token": "AT", "refresh_token": "RT", "expires_in": 3600, "token_type": "bearer" }
        """
    let token = try JSONDecoder().decode(FrameioToken.self, from: Data(json.utf8))
    #expect(token.accessToken == "AT")
    #expect(token.refreshToken == "RT")
    #expect(token.expiresIn == 3600)
}
