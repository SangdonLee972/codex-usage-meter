import Foundation

final class CodexProvider: UsageProvider {
    let id: ProviderID = .codex
    let displayName = "Codex"
    let icon: ProviderIcon = .codex
    let dashboardURL = URL(string: "https://chatgpt.com/codex/settings/usage")

    private let rateLimitReader = CodexRateLimitReader()
    private let tokenReader = CodexTokenReader()

    func loadSnapshotSync() -> UsageSnapshot {
        guard let history = rateLimitReader.latestSnapshotHistory() else {
            return UsageSnapshot(
                windows: [], extras: [], footerText: nil, observedAt: nil,
                inlineMessage: "No rate-limit snapshot found — open Codex once."
            )
        }

        let snapshot = history.latest
        let activity = tokenReader.tokenActivitySummary(recentWindowSeconds: 180)

        return UsageSnapshot(
            windows: [
                UsageWindow(
                    title: "5-hour window",
                    resetsAt: snapshot.primaryResetsAt,
                    usedPercent: snapshot.primaryUsedPercent,
                    deltaPercent: history.primaryLeftDelta,
                    isPrimary: true
                ),
                UsageWindow(
                    title: "Weekly window",
                    resetsAt: snapshot.secondaryResetsAt,
                    usedPercent: snapshot.secondaryUsedPercent,
                    deltaPercent: history.secondaryLeftDelta,
                    isPrimary: false
                )
            ],
            extras: [
                .tokenSummary(
                    lastTurn: TokenFormatter.menuValue(activity.latestTurnUsage),
                    recent: TokenFormatter.menuValue(activity.recentUsage),
                    latestCall: TokenFormatter.menuValue(activity.latestCallUsage)
                )
            ],
            footerText: footer(for: snapshot),
            observedAt: snapshot.observedAt,
            inlineMessage: nil
        )
    }

    private func footer(for snapshot: RateLimitSnapshot) -> String {
        var parts: [String] = ["Plan \(snapshot.planType)"]
        if let reached = snapshot.reachedType, !reached.isEmpty {
            parts.append("Limit: \(reached)")
        }
        return parts.joined(separator: " · ")
    }
}
