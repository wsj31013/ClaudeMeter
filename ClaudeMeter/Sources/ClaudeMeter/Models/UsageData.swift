import Foundation

struct UsageWindow: Codable {
    let percent: Double
    let resetAt: Date?

    var isNearLimit: Bool { percent >= 80 }
    var isCritical: Bool { percent >= 95 }

    var timeUntilReset: String? {
        guard let resetAt else { return nil }
        let diff = resetAt.timeIntervalSinceNow
        guard diff > 0 else { return "리셋됨" }
        let hours = Int(diff / 3600)
        let minutes = Int((diff.truncatingRemainder(dividingBy: 3600)) / 60)
        if hours > 0 { return "\(hours)시간 \(minutes)분 후 리셋" }
        return "\(minutes)분 후 리셋"
    }
}

struct UsageData {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
    let fetchedAt: Date

    var overallStatus: StatusLevel {
        let max = Swift.max(fiveHour.percent, sevenDay.percent)
        if max >= 95 { return .critical }
        if max >= 80 { return .warning }
        return .normal
    }
}

enum StatusLevel {
    case normal, warning, critical

    var menuBarLabel: String {
        switch self {
        case .normal: return "●"
        case .warning: return "◐"
        case .critical: return "○"
        }
    }
}

// Raw API response types
struct UsageAPIResponse: Decodable {
    let fiveHour: WindowRaw
    let sevenDay: WindowRaw

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

struct WindowRaw: Decodable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}
