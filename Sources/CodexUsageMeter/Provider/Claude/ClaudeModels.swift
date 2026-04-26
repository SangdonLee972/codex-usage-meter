import Foundation

struct ClaudeUsageWindow {
    let usedPercent: Double
    let resetsAt: Date?
}

struct ClaudeUsageSnapshot {
    let observedAt: Date
    let fiveHour: ClaudeUsageWindow?
    let sevenDay: ClaudeUsageWindow?
    let sevenDayOpus: ClaudeUsageWindow?
    let sevenDaySonnet: ClaudeUsageWindow?
}

enum ClaudeUsageStatus {
    case ok(ClaudeUsageSnapshot)
    case missingCredentials
    case missingScope
    case unauthorized
    case httpError(Int)
    case networkError(String)

    var snapshot: ClaudeUsageSnapshot? {
        if case .ok(let snapshot) = self { return snapshot }
        return nil
    }

    var menuMessage: String? {
        switch self {
        case .ok:
            return nil
        case .missingCredentials:
            return "Sign in: run `claude` once"
        case .missingScope:
            return "Token missing scope — run `claude login`"
        case .unauthorized:
            return "Token expired — run `claude login`"
        case .httpError(let code):
            return "HTTP \(code) from api.anthropic.com"
        case .networkError(let detail):
            return "Network error: \(detail)"
        }
    }
}
