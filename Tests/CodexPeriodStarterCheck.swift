// Run scripts/check-codex-period.sh after a debug build (no XCTest required).
import Foundation
@testable import PitStop

final class CodexPeriodStarterCheck {
    private let creds = Codex.Creds(accessToken: "test", accountId: "test-account",
                                   account: .init(email: "test@example.com", planLabel: "Pro"))

    private func report(used: Double = 0, duration: Int = 604800,
                        remaining: Int? = 604800, allowed: Bool = true,
                        reached: Bool = false, secondary: Bool = false) throws -> Codex.Usage {
        var window: [String: Any] = ["used_percent": used, "limit_window_seconds": duration,
                                     "reset_at": 1792708926]
        if let remaining { window["reset_after_seconds"] = remaining }
        let data = try JSONSerialization.data(withJSONObject: ["rate_limit": [
            "allowed": allowed, "limit_reached": reached,
            secondary ? "secondary_window" : "primary_window": window,
        ]])
        return try Codex.parseUsage(data)
    }

    func testExactIdleWeeklyWindowOnly() throws {
        checkEqual(try report().idlePeriodSeconds, 604800)
        checkEqual(try report(secondary: true).idlePeriodSeconds, 604800)
        checkNil(try report(used: 0.1).idlePeriodSeconds)
        checkNil(try report(remaining: 604799).idlePeriodSeconds)
        checkNil(try report(remaining: nil).idlePeriodSeconds)
        checkNil(try report(duration: 18000, remaining: 18000).idlePeriodSeconds)
        checkNil(try report(allowed: false).idlePeriodSeconds)
        checkNil(try report(reached: true).idlePeriodSeconds)
        // Old caches lack the new field and must remain readable.
        let old = Data(#"{"windows":[],"fetchedAt":0}"#.utf8)
        checkNil(try JSONDecoder().decode(Codex.Usage.self, from: old).idlePeriodSeconds)
    }

    func testCooldownAndRestart() throws {
        let now = Date()
        checkTrue(CodexPeriodStarter.shouldStart(usage: try report(), lastAttempt: nil, now: now))
        checkFalse(CodexPeriodStarter.shouldStart(usage: try report(), lastAttempt: now, now: now))
        checkFalse(CodexPeriodStarter.shouldStart(usage: try report(),
            lastAttempt: now.addingTimeInterval(-599), now: now))
        checkTrue(CodexPeriodStarter.shouldStart(usage: try report(),
            lastAttempt: now.addingTimeInterval(-600), now: now))
        checkFalse(CodexPeriodStarter.shouldStart(usage: try report(remaining: 604799),
            lastAttempt: nil, now: now))
    }

    func testGreetingAndStreamCompletion() throws {
        let request = try CodexPeriodStarter.greetingRequest(creds)
        checkEqual(request.value(forHTTPHeaderField: "chatgpt-account-id"), creds.accountId)
        let body = try unwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let input = try unwrap(body["input"] as? [[String: Any]])
        let content = try unwrap(input.first?["content"] as? [[String: String]])
        checkEqual(content.first?["text"], "Привет")
        checkEqual(body["store"] as? Bool, false)
        checkNil(body["tools"])
        try CodexPeriodStarter.validateCompletion(Data("data: {\"type\":\"response.created\"}\r\n\r\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\r\n\r\n".utf8))
        for stream in ["", "data: [DONE]\n", "data: {\"type\":\"response.failed\"}\n",
                       "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"incomplete\"}}\n"] {
            checkThrows(try CodexPeriodStarter.validateCompletion(Data(stream.utf8)))
        }
    }
}

func checkEqual<T: Equatable>(_ value: T, _ expected: T) { precondition(value == expected) }
func checkNil<T>(_ value: T?) { precondition(value == nil) }
func checkTrue(_ value: Bool) { precondition(value) }
func checkFalse(_ value: Bool) { precondition(!value) }
func unwrap<T>(_ value: T?) throws -> T { precondition(value != nil); return value! }
func checkThrows(_ body: @autoclosure () throws -> Void) {
    do { try body(); preconditionFailure("Expected an error") } catch {}
}

let checks = CodexPeriodStarterCheck()
try checks.testExactIdleWeeklyWindowOnly()
try checks.testCooldownAndRestart()
try checks.testGreetingAndStreamCompletion()
print("Codex period checks passed")
