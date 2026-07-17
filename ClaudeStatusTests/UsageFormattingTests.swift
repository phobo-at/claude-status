import Foundation
import XCTest
@testable import ClaudeStatus

final class UsageFormattingTests: XCTestCase {
    private let germanLocale = Locale(identifier: "de_AT")
    private let englishLocale = Locale(identifier: "en_US")
    private let vienna = TimeZone(identifier: "Europe/Vienna")!

    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// The *language* of a localized string comes from the bundle; `locale:` only formats the
    /// interpolated values. So these tests pin the German bundle explicitly — otherwise the
    /// result would depend on the language of whatever Mac runs the suite (German locally,
    /// English on CI). Asserting the German round-trip is also the point: it proves the key the
    /// code generates matches the key in the catalog. A mismatch falls back to the English key,
    /// which looks fine in English and silently ships English to German users.
    private func germanBundle() throws -> Bundle {
        let path = try XCTUnwrap(
            Bundle.main.path(forResource: "de", ofType: "lproj"),
            "app bundle carries no de.lproj — is Localizable.xcstrings in the ClaudeStatus target?"
        )
        return try XCTUnwrap(Bundle(path: path))
    }

    /// macOS formats en_US times with a narrow no-break space (U+202F) before AM/PM. It is
    /// indistinguishable from a normal space in a failure diff, so fold the space variants
    /// rather than pasting an invisible character into this file.
    private func normalizingSpaces(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    func testPercentageRoundsToWholeNumber() {
        XCTAssertEqual(UsageFormatting.percentage(14.4), "14 %")
        XCTAssertEqual(UsageFormatting.percentage(14.5), "15 %")
    }

    func testRelativeResetFormatting() throws {
        let bundle = try germanBundle()
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(
            UsageFormatting.sessionResetText(
                resetsAt: now.addingTimeInterval((4 * 60 * 60) + (16 * 60)),
                now: now, calendar: utc, locale: germanLocale, bundle: bundle
            ),
            "Zurücksetzung in 4 Std. 16 Min."
        )
        XCTAssertEqual(
            UsageFormatting.sessionResetText(
                resetsAt: now.addingTimeInterval(16 * 60),
                now: now, calendar: utc, locale: germanLocale, bundle: bundle
            ),
            "Zurücksetzung in 16 Min."
        )
    }

    func testResetEdgeCases() throws {
        let bundle = try germanBundle()
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(
            UsageFormatting.sessionResetText(
                resetsAt: now, now: now, calendar: utc, locale: germanLocale, bundle: bundle
            ),
            "Zurücksetzung fällig"
        )
        XCTAssertEqual(
            UsageFormatting.sessionResetText(
                resetsAt: nil, now: now, calendar: utc, locale: germanLocale, bundle: bundle
            ),
            "Zurücksetzungszeit unbekannt"
        )
    }

    func testWeeklyResetFormatting() throws {
        let bundle = try germanBundle()
        let reset = try XCTUnwrap(FlexibleISO8601Date.parse("2026-07-20T22:59:00Z"))

        XCTAssertEqual(
            UsageFormatting.weeklyResetText(
                resetsAt: reset, timeZone: vienna, locale: germanLocale, bundle: bundle
            ),
            "Zurücksetzung Di., 00:59"
        )
    }

    func testRetryAfterFormatting() throws {
        let bundle = try germanBundle()
        let retryAt = try XCTUnwrap(FlexibleISO8601Date.parse("2026-07-17T06:47:00Z"))

        XCTAssertEqual(
            UsageFormatting.retryAfterText(
                until: retryAt, timeZone: vienna, locale: germanLocale, bundle: bundle
            ),
            "Neuer Versuch um 08:47"
        )
    }

    func testUpdatedTextAcrossAllBranches() throws {
        let bundle = try germanBundle()
        let fetchedAt = Date(timeIntervalSince1970: 1_000_000)

        func updated(_ minutes: Double) -> String {
            UsageFormatting.updatedText(
                fetchedAt: fetchedAt,
                now: fetchedAt.addingTimeInterval(minutes * 60),
                calendar: utc, timeZone: vienna, locale: germanLocale, bundle: bundle
            )
        }

        XCTAssertEqual(updated(0), "Gerade aktualisiert")
        XCTAssertEqual(updated(1), "Vor 1 Minute aktualisiert")
        XCTAssertEqual(updated(42), "Vor 42 Minuten aktualisiert")
        XCTAssertEqual(updated(90), "Aktualisiert um 14:46")
    }

    /// Dates and times must follow the user's locale, not the UI language — the formatters used
    /// to hardcode `de_AT`, which would have given an English user "Di., 00:59". Same bundle in
    /// both calls, so the prose stays German and only the clock and weekday move.
    func testDatesFollowTheLocaleAndNotTheLanguage() throws {
        let bundle = try germanBundle()
        let retryAt = try XCTUnwrap(FlexibleISO8601Date.parse("2026-07-17T06:47:00Z"))
        let reset = try XCTUnwrap(FlexibleISO8601Date.parse("2026-07-20T22:59:00Z"))

        XCTAssertEqual(
            normalizingSpaces(UsageFormatting.retryAfterText(
                until: retryAt, timeZone: vienna, locale: englishLocale, bundle: bundle
            )),
            "Neuer Versuch um 8:47 AM"
        )
        XCTAssertEqual(
            normalizingSpaces(UsageFormatting.weeklyResetText(
                resetsAt: reset, timeZone: vienna, locale: englishLocale, bundle: bundle
            )),
            "Zurücksetzung Tue, 12:59 AM"
        )
    }

    func testWarningThresholds() {
        XCTAssertEqual(UsageWarningLevel(utilization: 79.9), .normal)
        XCTAssertEqual(UsageWarningLevel(utilization: 80), .elevated)
        XCTAssertEqual(UsageWarningLevel(utilization: 94.9), .elevated)
        XCTAssertEqual(UsageWarningLevel(utilization: 95), .critical)
    }
}
