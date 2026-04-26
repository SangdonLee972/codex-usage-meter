import Foundation

struct RateLimitSnapshot {
    let observedAt: Date
    let planType: String
    let primaryUsedPercent: Double
    let primaryResetsAt: Date?
    let secondaryUsedPercent: Double
    let secondaryResetsAt: Date?
    let credits: String?
    let reachedType: String?
}

struct UsageSnapshotHistory {
    let latest: RateLimitSnapshot
    let previousDistinct: RateLimitSnapshot?

    var primaryLeftDelta: Double? {
        leftDelta(latestUsed: latest.primaryUsedPercent, previousUsed: previousDistinct?.primaryUsedPercent)
    }

    var secondaryLeftDelta: Double? {
        leftDelta(latestUsed: latest.secondaryUsedPercent, previousUsed: previousDistinct?.secondaryUsedPercent)
    }

    private func leftDelta(latestUsed: Double, previousUsed: Double?) -> Double? {
        guard let previousUsed else { return nil }
        return (100 - latestUsed) - (100 - previousUsed)
    }
}

struct TokenUsage {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64

    static let zero = TokenUsage(inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 0)

    func adding(_ other: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: inputTokens + other.inputTokens,
            cachedInputTokens: cachedInputTokens + other.cachedInputTokens,
            outputTokens: outputTokens + other.outputTokens,
            reasoningOutputTokens: reasoningOutputTokens + other.reasoningOutputTokens,
            totalTokens: totalTokens + other.totalTokens
        )
    }

    func delta(from previous: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: max(0, inputTokens - previous.inputTokens),
            cachedInputTokens: max(0, cachedInputTokens - previous.cachedInputTokens),
            outputTokens: max(0, outputTokens - previous.outputTokens),
            reasoningOutputTokens: max(0, reasoningOutputTokens - previous.reasoningOutputTokens),
            totalTokens: max(0, totalTokens - previous.totalTokens)
        )
    }
}

struct TokenUsageEvent {
    let source: String
    let observedAt: Date
    let sequence: Int
    let totalUsage: TokenUsage
    let lastUsage: TokenUsage
}

struct TokenSessionScan {
    let source: String
    let taskStarts: [Date]
    let tokenEvents: [TokenUsageEvent]
}

struct TokenActivitySummary {
    let latestCallUsage: TokenUsage?
    let latestTurnUsage: TokenUsage?
    let recentUsage: TokenUsage
    let recentWindowSeconds: TimeInterval

    static func empty(recentWindowSeconds: TimeInterval) -> TokenActivitySummary {
        TokenActivitySummary(
            latestCallUsage: nil,
            latestTurnUsage: nil,
            recentUsage: .zero,
            recentWindowSeconds: recentWindowSeconds
        )
    }
}

struct LocalTokenStats {
    let lastFiveHours: Int64?
    let today: Int64?
    let total: Int64?
}

enum CodexPaths {
    static let sessionsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)
    static let stateDB = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/state_5.sqlite").path
}
