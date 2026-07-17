import Foundation
import XCTest
@testable import ClaudeStatus

/// The app ships English source strings with German as a translation. A key the code asks for
/// that the catalog does not carry fails *silently*: the lookup falls back to the English key,
/// so a German user just sees English and nothing crashes. These tests are the only thing that
/// catches that, so every user-facing key belongs in `keys` below.
final class LocalizationTests: XCTestCase {
    private static let sentinel = "@@NO_TRANSLATION@@"

    private func germanBundle() throws -> Bundle {
        let path = try XCTUnwrap(
            Bundle.main.path(forResource: "de", ofType: "lproj"),
            "app bundle carries no de.lproj — is Localizable.xcstrings in the ClaudeStatus target?"
        )
        return try XCTUnwrap(Bundle(path: path))
    }

    func testAppBundleShipsBothLocalizations() {
        let localizations = Set(Bundle.main.localizations)
        XCTAssertTrue(localizations.contains("en"), "missing en — got \(localizations.sorted())")
        XCTAssertTrue(localizations.contains("de"), "missing de — got \(localizations.sorted())")
    }

    func testEveryUserFacingKeyHasAGermanTranslation() throws {
        let bundle = try germanBundle()
        let missing = Self.keys.filter {
            bundle.localizedString(forKey: $0, value: Self.sentinel, table: nil) == Self.sentinel
        }
        XCTAssertTrue(missing.isEmpty, "no German translation for:\n - \(missing.joined(separator: "\n - "))")
    }

    func testGermanTranslationsAreActuallyTranslated() throws {
        let bundle = try germanBundle()
        let untranslated = Self.keys.filter {
            bundle.localizedString(forKey: $0, value: nil, table: nil) == $0
        }
        XCTAssertTrue(
            untranslated.isEmpty,
            "still verbatim English in de.lproj:\n - \(untranslated.joined(separator: "\n - "))"
        )
    }

    /// Placeholder counts must survive translation — a German value that drops or reorders a
    /// specifier feeds `String(format:)` garbage at runtime.
    func testPlaceholdersSurviveTranslation() throws {
        let bundle = try germanBundle()
        for key in Self.keys {
            let translated = bundle.localizedString(forKey: key, value: nil, table: nil)
            XCTAssertEqual(
                Self.specifiers(in: key), Self.specifiers(in: translated),
                "placeholder mismatch for \"\(key)\" → \"\(translated)\""
            )
        }
    }

    private static func specifiers(in value: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%(?:lld|d|@)")
        let range = NSRange(value.startIndex..., in: value)
        return pattern.matches(in: value, range: range).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }
    }

    private static let keys = [
        "%@ used",
        "Access to the Claude Code login was denied.",
        "After you allow it, Claude Status reads your existing Claude Code login from the macOS Keychain once per app launch. It then stays in memory only, and is never stored or logged.",
        "All models",
        "Check again",
        "Claude is temporarily unavailable (HTTP %lld).",
        "Claude received too many refreshes.",
        "Claude returned no usage limits.",
        "Claude sent an unexpected response.",
        "Claude sign-in required",
        "Claude usage unavailable",
        "Claude usage, current session: %@ used",
        "Connect to Claude Code",
        "Copied",
        "Copy claude auth login",
        "Current session",
        "Just updated",
        "Loading usage …",
        "Next attempt at %@",
        "No Claude Code login found. Run “claude auth login” first.",
        "Not updated yet",
        "Opus only",
        "Plan usage limits",
        "Quit Claude Status",
        "Refresh usage",
        "Reset due",
        "Reset time unknown",
        "Resets %@",
        "Resets in %lld hr %lld min",
        "Resets in %lld min",
        "Run the following command in Terminal, then check the connection again.",
        "Sonnet only",
        "The macOS Keychain could not be read (error %d).",
        "The secure connection to Claude could not be verified.",
        "The stored Claude Code login has an unknown format.",
        "Try again",
        "Updated 1 minute ago",
        "Updated %lld minutes ago",
        "Updated at %@",
        "Weekly limits",
        "Your Claude login has expired.",
    ]
}
