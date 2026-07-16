import Foundation

struct LimitWindow: Codable, Equatable, Sendable {
    let utilization: Double
    let resetsAt: Date?

    init(utilization: Double, resetsAt: Date?) {
        if utilization.isFinite {
            self.utilization = min(max(utilization, 0), 100)
        } else {
            self.utilization = 0
        }
        self.resetsAt = resetsAt
    }

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let utilization = try container.decode(Double.self, forKey: .utilization)

        let resetsAt: Date?
        if let rawDate = try container.decodeIfPresent(String.self, forKey: .resetsAt) {
            resetsAt = FlexibleISO8601Date.parse(rawDate)
        } else {
            resetsAt = nil
        }

        self.init(utilization: utilization, resetsAt: resetsAt)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(utilization, forKey: .utilization)
        if let resetsAt {
            try container.encode(FlexibleISO8601Date.string(from: resetsAt), forKey: .resetsAt)
        }
    }
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    let currentSession: LimitWindow?
    let weeklyAllModels: LimitWindow?
    let weeklySonnet: LimitWindow?
    let weeklyOpus: LimitWindow?
    let fetchedAt: Date

    var hasAnyLimit: Bool {
        currentSession != nil || weeklyAllModels != nil || weeklySonnet != nil || weeklyOpus != nil
    }
}

struct UsagePayload: Decodable, Sendable {
    let fiveHour: LimitWindow?
    let sevenDay: LimitWindow?
    let sevenDaySonnet: LimitWindow?
    let sevenDayOpus: LimitWindow?

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
    }

    func snapshot(fetchedAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            currentSession: fiveHour,
            weeklyAllModels: sevenDay,
            weeklySonnet: sevenDaySonnet,
            weeklyOpus: sevenDayOpus,
            fetchedAt: fetchedAt
        )
    }
}

enum UsageWarningLevel: Equatable, Sendable {
    case normal
    case elevated
    case critical

    init(utilization: Double) {
        if utilization >= 95 {
            self = .critical
        } else if utilization >= 80 {
            self = .elevated
        } else {
            self = .normal
        }
    }
}

enum FlexibleISO8601Date {
    static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

