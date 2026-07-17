import Foundation
import XCTest
@testable import ClaudeStatus

final class UsageFormattingTests: XCTestCase {
    func testPercentageRoundsToWholeNumber() {
        XCTAssertEqual(UsageFormatting.percentage(14.4), "14 %")
        XCTAssertEqual(UsageFormatting.percentage(14.5), "15 %")
    }

    func testRelativeResetFormatting() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval((4 * 60 * 60) + (16 * 60))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        XCTAssertEqual(
            UsageFormatting.sessionResetText(resetsAt: reset, now: now, calendar: calendar),
            "Zurücksetzung in 4 Std. 16 Min."
        )
        XCTAssertEqual(
            UsageFormatting.sessionResetText(resetsAt: now, now: now, calendar: calendar),
            "Zurücksetzung fällig"
        )
    }

    func testWeeklyResetFormattingUsesRequestedTimeZone() throws {
        let reset = try XCTUnwrap(FlexibleISO8601Date.parse("2026-07-20T22:59:00Z"))
        let text = UsageFormatting.weeklyResetText(
            resetsAt: reset,
            timeZone: TimeZone(identifier: "Europe/Vienna")!
        )

        XCTAssertTrue(text.hasPrefix("Zurücksetzung"))
        XCTAssertTrue(text.contains("00:59"))
    }

    func testRetryAfterFormattingUsesRequestedTimeZone() throws {
        let retryAt = try XCTUnwrap(FlexibleISO8601Date.parse("2026-07-17T06:47:00Z"))
        let text = UsageFormatting.retryAfterText(
            until: retryAt,
            timeZone: TimeZone(identifier: "Europe/Vienna")!
        )

        XCTAssertEqual(text, "Neuer Versuch um 08:47")
    }

    func testWarningThresholds() {
        XCTAssertEqual(UsageWarningLevel(utilization: 79.9), .normal)
        XCTAssertEqual(UsageWarningLevel(utilization: 80), .elevated)
        XCTAssertEqual(UsageWarningLevel(utilization: 94.9), .elevated)
        XCTAssertEqual(UsageWarningLevel(utilization: 95), .critical)
    }
}

