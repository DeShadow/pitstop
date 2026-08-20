import XCTest
@testable import PitStop

final class OpenCodeTests: XCTestCase {
    func testAPIKeyReadsOpenCodeGoEntryOnly() throws {
        let data = Data(#"{"openai":{"type":"api","key":"openai-key"},"opencode-go":{"type":"api","key":"go-key"}}"#.utf8)
        XCTAssertEqual(OpenCode.apiKey(from: data), "go-key")
    }

    func testAPIKeyRejectsOtherAuthShapes() throws {
        let data = Data(#"{"opencode-go":{"type":"oauth","key":"not-an-api-key"}}"#.utf8)
        XCTAssertNil(OpenCode.apiKey(from: data))
    }

    func testParseUsageMapsWindowsAndRelativeResets() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let data = Data(#"{"useBalance":true,"rollingUsage":{"usagePercent":65,"resetInSec":3600},"weeklyUsage":{"usagePercent":30,"resetInSec":7200},"monthlyUsage":{"usagePercent":12,"resetInSec":86400}}"#.utf8)

        let usage = try OpenCode.parseUsage(data, now: now)

        XCTAssertTrue(usage.useBalance)
        XCTAssertEqual(usage.windows.map(\.label), ["5h", "7d", "30d"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [65, 30, 12])
        XCTAssertEqual(usage.windows[0].resetsAt, now.addingTimeInterval(3600))
        XCTAssertEqual(usage.windows[2].resetsAt, now.addingTimeInterval(86400))
    }

    func testParseCurrentUsageShapeWithAbsoluteResets() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let data = Data(#"{"usage":{"rolling":{"percent":29,"resetsAt":"1970-01-01T01:16:40.000Z"},"weekly":{"percent":11,"resetsAt":"1970-01-01T02:00:00.000Z"},"monthly":{"percent":5,"resetsAt":"1970-01-02T00:00:00.000Z"}}}"#.utf8)

        let usage = try OpenCode.parseUsage(data, now: now)

        XCTAssertEqual(usage.windows.map(\.usedPercent), [29, 11, 5])
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 4600))
    }

    func testParseUsageClampsPercentages() throws {
        let data = Data(#"{"rollingUsage":{"usagePercent":120},"weeklyUsage":{"usagePercent":-5}}"#.utf8)
        let usage = try OpenCode.parseUsage(data)
        XCTAssertEqual(usage.windows.map(\.usedPercent), [100, 0])
    }
}
