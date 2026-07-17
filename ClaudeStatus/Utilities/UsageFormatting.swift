import Foundation

enum UsageFormatting {
    static let germanLocale = Locale(identifier: "de_AT")

    static func percentage(_ value: Double) -> String {
        "\(Int(value.rounded())) %"
    }

    static func sessionResetText(
        resetsAt: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        guard let resetsAt else {
            return "Zurücksetzungszeit unbekannt"
        }
        guard resetsAt > now else {
            return "Zurücksetzung fällig"
        }

        let components = calendar.dateComponents([.day, .hour, .minute], from: now, to: resetsAt)
        let totalHours = max(0, (components.day ?? 0) * 24 + (components.hour ?? 0))
        let minutes = max(0, components.minute ?? 0)

        if totalHours > 0 {
            return "Zurücksetzung in \(totalHours) Std. \(minutes) Min."
        }
        return "Zurücksetzung in \(minutes) Min."
    }

    static func weeklyResetText(
        resetsAt: Date?,
        timeZone: TimeZone = .current
    ) -> String {
        guard let resetsAt else {
            return "Zurücksetzungszeit unbekannt"
        }

        let formatter = DateFormatter()
        formatter.locale = germanLocale
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, HH:mm"
        return "Zurücksetzung \(formatter.string(from: resetsAt))"
    }

    /// Absolute time rather than a countdown: the popover does not tick, so "in 29 Min."
    /// would be a lie the moment it is drawn.
    static func retryAfterText(
        until: Date,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = germanLocale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "Neuer Versuch um \(formatter.string(from: until))"
    }

    static func updatedText(
        fetchedAt: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let minutes = max(0, calendar.dateComponents([.minute], from: fetchedAt, to: now).minute ?? 0)
        if minutes == 0 {
            return "Gerade aktualisiert"
        }
        if minutes == 1 {
            return "Vor 1 Minute aktualisiert"
        }
        if minutes < 60 {
            return "Vor \(minutes) Minuten aktualisiert"
        }

        let formatter = DateFormatter()
        formatter.locale = germanLocale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "Aktualisiert um \(formatter.string(from: fetchedAt))"
    }
}

