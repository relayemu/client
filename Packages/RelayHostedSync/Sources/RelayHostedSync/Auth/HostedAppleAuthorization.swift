// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices

@MainActor
public enum HostedAppleAuthorization {
    /// Native AuthenticationServices supports iOS, macOS and tvOS. UI owns the
    /// authorization controller's presentation anchor and delegate lifecycle.
    public static func request(for challenge: HostedAppleChallenge) -> ASAuthorizationAppleIDRequest {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        configure(request, for: challenge)
        return request
    }
    public static func configure(_ request: ASAuthorizationAppleIDRequest, for challenge: HostedAppleChallenge) {
        request.requestedScopes = []
        // Protocol v1 stores SHA256(nonce) on the server. Apple receives the
        // original nonce, not a locally rehashed nonce.
        request.nonce = challenge.nonce
        request.state = challenge.challengeID.uuidString.lowercased()
    }
    public static func identityToken(from authorization: ASAuthorization, for challenge: HostedAppleChallenge) throws -> Data {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              credential.state == challenge.challengeID.uuidString.lowercased(),
              let token = credential.identityToken, !token.isEmpty else { throw HostedAuthError.invalidResponse }
        return token
    }
}
#endif
