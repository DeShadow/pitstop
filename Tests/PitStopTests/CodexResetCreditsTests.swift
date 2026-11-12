import XCTest
@testable import PitStop

final class CodexResetCreditsTests: XCTestCase {
    func testShowsOneLinePerAvailableResetInExpiryOrder() async throws {
        let usage = try await fetchUsage(account: "saved")
        let credits = try XCTUnwrap(usage.resetCredits)
        XCTAssertEqual(credits.availableCount, 3)
        XCTAssertEqual(credits.expirations, [
            try Date.ISO8601FormatStyle().parse("2026-12-02T01:44:00Z"),
            try Date.ISO8601FormatStyle().parse("2026-12-12T01:44:00Z"),
            nil,
        ])

        let lines = Format.resetCreditLines(credits)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("3 resets · Expires "))
        XCTAssertTrue(lines[1].hasPrefix("Expires "))
        XCTAssertEqual(lines[2], "No expiration")
    }

    func testDetailsFailurePreservesQuotaAndResetCount() async throws {
        let usage = try await fetchUsage(account: "throttled")
        XCTAssertEqual(usage.windows.first?.usedPercent, 25)
        XCTAssertEqual(Format.resetCreditLines(usage.resetCredits), [
            "2 resets · Expiry unavailable", "Expiry unavailable",
        ])
    }

    func testDistinguishesZeroFromUnknownCount() async throws {
        let zero = try await fetchUsage(account: "zero")
        XCTAssertEqual(Format.resetCreditLines(zero.resetCredits), ["0 resets"])
        let unknown = try await fetchUsage(account: "unknown")
        XCTAssertEqual(Format.resetCreditLines(unknown.resetCredits), ["Reset count unavailable"])
    }

    private func fetchUsage(account: String) async throws -> Codex.Usage {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResetCreditsStub.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let creds = Codex.Creds(accessToken: "\(account)-token", refreshToken: nil,
                                accountId: account, account: .init(email: "", planLabel: ""))
        return try await Codex.fetchUsage(creds, session: session)
    }
}

private final class ResetCreditsStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let account = request.value(forHTTPHeaderField: "chatgpt-account-id")
        guard let url = request.url, let account,
              request.httpMethod == "GET",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer \(account)-token" else {
            XCTFail("Expected a read using the requested account's credentials")
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let status: Int
        let body: String
        switch (url.path, account) {
        case ("/backend-api/codex/usage", _):
            let counts = ["saved": 3, "throttled": 2, "zero": 0]
            let summary = counts[account].map {
                #", "rate_limit_reset_credits": {"available_count": \#($0)}"#
            } ?? ""
            status = 200
            body = #"{"rate_limit": {"primary_window": {"used_percent": 25}}\#(summary)}"#
        case ("/backend-api/wham/rate-limit-reset-credits", "saved"):
            status = 200
            body = """
                {"available_count": 3, "credits": [
                    {"status": "available", "expires_at": null},
                    {"status": "available", "expires_at": "2026-12-12T01:44:00.000Z"},
                    {"status": "used", "expires_at": "2026-11-13T01:44:00Z"},
                    {"status": "available", "expires_at": "2026-12-02T01:44:00Z"}
                ]}
                """
        case ("/backend-api/wham/rate-limit-reset-credits", "throttled"):
            status = 429
            body = "{}"
        default:
            XCTFail("Unexpected request for \(account) at \(url.path)")
            status = 404
            body = "{}"
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
