import XCTest
@testable import PitStop

final class MenuBarSourceTests: XCTestCase {
    func testActiveCodexAccountIsAvailable() {
        XCTAssertEqual(MenuBarSource.allCases.map(\.label), [
            "Active Claude Code account",
            "Active Codex account",
            "Most-used account (any provider)",
        ])
    }

    func testActiveCodexAccountRoundTripsThroughSettings() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "menuBarSource")
        defer {
            if let previous {
                defaults.set(previous, forKey: "menuBarSource")
            } else {
                defaults.removeObject(forKey: "menuBarSource")
            }
        }

        defaults.set(MenuBarSource.activeCodex.rawValue, forKey: "menuBarSource")
        XCTAssertEqual(Settings.menuBarSource, .activeCodex)
    }

    func testActiveCodexReadingUsesTheLiveAccountsHighestWindow() {
        let report = Codex.Usage(windows: [
            .init(label: "5h", usedPercent: 42.1, resetsAt: nil),
            .init(label: "7d", usedPercent: 84.6, resetsAt: nil),
        ])

        let reading = activeCodexMenuBarReading(
            liveEmail: "me@example.com",
            usage: ["codex:me@example.com": report],
            fetchError: [:]
        )

        XCTAssertEqual(reading.pct, 85)
        XCTAssertFalse(reading.isStale)
        XCTAssertEqual(reading.tip, "me@example.com (Codex)\n5h 42% · 7d 85%")
    }

    func testActiveCodexReadingHandlesMissingAccountAndStaleData() {
        XCTAssertEqual(
            activeCodexMenuBarReading(liveEmail: nil, usage: [:], fetchError: [:]),
            MenuBarReading(pct: nil, isStale: false,
                           tip: "PitStop — no active Codex account")
        )

        let report = Codex.Usage(windows: [
            .init(label: "5h", usedPercent: 75, resetsAt: nil),
        ], fetchedAt: Date(timeIntervalSince1970: 0))
        let reading = activeCodexMenuBarReading(
            liveEmail: "me@example.com",
            usage: ["codex:me@example.com": report],
            fetchError: ["codex:me@example.com": "Rate limited"]
        )

        XCTAssertEqual(reading.pct, 75)
        XCTAssertTrue(reading.isStale)
        XCTAssertTrue(reading.tip.contains("⚠️ Rate limited — showing data from"))
    }
}
