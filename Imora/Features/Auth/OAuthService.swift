import AuthenticationServices
import CryptoKit
import UIKit

/// pkce values for one oauth attempt.
nonisolated struct PKCE {
    let state: String
    let verifier: String
    let challenge: String

    init() {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        state = String((0..<32).map { _ in alphabet.randomElement()! })
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        verifier = Data(bytes).base64URLEncoded()
        challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }
}

nonisolated extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// drives the system web auth sheet and the immich oauth endpoints.
/// uses the same redirect uri as the official app so existing idp
/// client configurations keep working.
final class OAuthService: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let redirectUri = "app.immich:///oauth-callback"
    static let callbackScheme = "app.immich"
    static let shared = OAuthService()

    private var activeSession: ASWebAuthenticationSession?

    /// runs the full flow and returns the logged-in credentials.
    /// returns nil when the user cancels the sheet.
    func logIn(apiURL: URL) async throws -> LoginResponse? {
        let pkce = PKCE()
        let authorizeURL = try await ImmichClient.oauthAuthorize(
            apiURL: apiURL,
            redirectUri: Self.redirectUri,
            state: pkce.state,
            codeChallenge: pkce.challenge
        )

        let callback: URL
        do {
            callback = try await authenticate(url: authorizeURL)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return nil
        }

        // some idps collapse the triple slash; normalize like the official app.
        var callbackString = callback.absoluteString
        if callbackString.hasPrefix("app.immich:/oauth-callback") {
            callbackString = callbackString.replacingOccurrences(
                of: "app.immich:/oauth-callback",
                with: "app.immich:///oauth-callback"
            )
        }

        return try await ImmichClient.oauthCallback(
            apiURL: apiURL,
            callbackURL: callbackString,
            state: pkce.state,
            codeVerifier: pkce.verifier
        )
    }

    private func authenticate(url: URL) async throws -> URL {
        // the session cancels itself when presented before a window exists,
        // which happens on auto-launch right after startup.
        for _ in 0..<20 {
            let hasWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .contains { !$0.bounds.isEmpty }
            if hasWindow { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.callbackScheme) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? ImmichError.unreachable)
                }
            }
            session.presentationContextProvider = self
            activeSession = session
            if !session.start() {
                activeSession = nil
                continuation.resume(throwing: ImmichError.unreachable)
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        if let window = windows.first(where: \.isKeyWindow) ?? windows.first {
            return window
        }
        if let scene = scenes.first {
            return ASPresentationAnchor(windowScene: scene)
        }
        // oauth is only started from on screen ui, so a scene always exists.
        preconditionFailure("no window scene available for oauth presentation")
    }
}
