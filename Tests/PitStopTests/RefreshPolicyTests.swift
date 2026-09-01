import XCTest
@testable import PitStop

final class RefreshPolicyTests: XCTestCase {
    func testRefreshesEveryMinute() {
        XCTAssertEqual(RefreshPolicy.interval, 60)
    }

    func testUsageEndpointRejectsAreTransient() throws {
        for status in [401, 403] {
            let error = try XCTUnwrap(Codex.usageResponseError(statusCode: status,
                                                               retryAfter: nil))
            guard let codexError = error as? Codex.CodexError else {
                return XCTFail("Expected a Codex error for HTTP \(status)")
            }
            XCTAssertEqual(codexError, .usageTemporarilyUnavailable)
            XCTAssertEqual(
                RefreshPolicy.codexFailureAction(codexError, failureCount: 1),
                .retryAfter(60)
            )
        }
    }

    func testRepeatedUsageRejectionsBackOffWithoutRequiringLogin() {
        XCTAssertEqual(
            RefreshPolicy.codexFailureAction(.usageTemporarilyUnavailable,
                                             failureCount: 2),
            .retryAfter(120)
        )
        XCTAssertEqual(
            RefreshPolicy.codexFailureAction(.usageTemporarilyUnavailable,
                                             failureCount: 10),
            .retryAfter(UsageCache.maxBackoff)
        )
    }

    func testRealSessionExpiryStillRequiresUserAction() {
        XCTAssertEqual(
            RefreshPolicy.codexFailureAction(.sessionExpired, failureCount: 1),
            .needsUserAction
        )
    }

    func testSuccessfulUsageResponseHasNoError() {
        XCTAssertNil(Codex.usageResponseError(statusCode: 200, retryAfter: nil))
    }
}
