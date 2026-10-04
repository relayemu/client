// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import RelayHostedSync
@testable import RelayUI

@MainActor final class RelayAccountFailureTests: XCTestCase {
    func testRejectedSignInDoesNotClaimAnExistingSessionExpired() {
        let error = HostedHTTPError(status: 401, problem: .accountUnavailable)
        XCTAssertEqual(RelayAccountModel.failureMessage(for: error, duringSignIn: true),
                       L("Apple sign-in could not be completed. Please try again."))
        XCTAssertEqual(RelayAccountModel.failureMessage(for: error),
                       L("Your session has expired. Sign in with Apple again."))
    }

    func testCancellationStaysQuietAndProviderDetailsStayPrivate() {
        XCTAssertNil(RelayAccountModel.failureMessage(for: CancellationError(), duringSignIn: true))
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "private provider detail"])
        XCTAssertEqual(RelayAccountModel.failureMessage(for: error, duringSignIn: true),
                       L("Apple sign-in could not be completed. Please try again."))
    }
}
