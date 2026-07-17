import Foundation

enum UsageFormatting {
    static func percentage(_ value: Double) -> String {
        "\(Int(value.rounded())) %"
    }

    static func sessionResetText(
        resetsAt: Date?,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current,
        bundle: Bundle = .main
    ) -> String {
        guard let resetsAt else {
            return String(localized: "Reset time unknown", bundle: bundle, locale: locale)
        }
        guard resetsAt > now else {
            return String(localized: "Reset due", bundle: bundle, locale: locale)
        }

        let components = calendar.dateComponents([.day, .hour, .minute], from: now, to: resetsAt)
        let totalHours = max(0, (components.day ?? 0) * 24 + (components.hour ?? 0))
        let minutes = max(0, components.minute ?? 0)

        if totalHours > 0 {
            return String(localized: "Resets in \(totalHours) hr \(minutes) min", bundle: bundle, locale: locale)
        }
        return String(localized: "Resets in \(minutes) min", bundle: bundle, locale: locale)
    }

    static func weeklyResetText(
        resetsAt: Date?,
        timeZone: TimeZone = .current,
        locale: Locale = .current,
        bundle: Bundle = .main
    ) -> String {
        guard let resetsAt else {
            return String(localized: "Reset time unknown", bundle: bundle, locale: locale)
        }

        // The clock goes through timeText like every other time this app prints, so a 12-hour
        // locale gets a 12-hour weekly reset too. Formatting it here as "HH:mm" would force
        // 24-hour on everyone — the same mistake as hardcoding the locale.
        let weekday = DateFormatter()
        weekday.locale = locale
        weekday.timeZone = timeZone
        weekday.dateFormat = "EEE"

        let reset = "\(weekday.string(from: resetsAt)), \(timeText(resetsAt, timeZone: timeZone, locale: locale))"
        return String(localized: "Resets \(reset)", bundle: bundle, locale: locale)
    }

    /// Absolute time rather than a countdown: the popover does not tick, so "in 29 min"
    /// would be a lie the moment it is drawn.
    static func retryAfterText(
        until: Date,
        timeZone: TimeZone = .current,
        locale: Locale = .current,
        bundle: Bundle = .main
    ) -> String {
        String(localized: "Next attempt at \(timeText(until, timeZone: timeZone, locale: locale))", bundle: bundle, locale: locale)
    }

    static func updatedText(
        fetchedAt: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        timeZone: TimeZone = .current,
        locale: Locale = .current,
        bundle: Bundle = .main
    ) -> String {
        let minutes = max(0, calendar.dateComponents([.minute], from: fetchedAt, to: now).minute ?? 0)
        if minutes == 0 {
            return String(localized: "Just updated", bundle: bundle, locale: locale)
        }
        if minutes == 1 {
            return String(localized: "Updated 1 minute ago", bundle: bundle, locale: locale)
        }
        if minutes < 60 {
            return String(localized: "Updated \(minutes) minutes ago", bundle: bundle, locale: locale)
        }
        return String(localized: "Updated at \(timeText(fetchedAt, timeZone: timeZone, locale: locale))", bundle: bundle, locale: locale)
    }

    private static func timeText(_ date: Date, timeZone: TimeZone, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
