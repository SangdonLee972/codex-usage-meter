import Foundation

final class ClaudeProvider: UsageProvider {
    let id: ProviderID = .claude
    let displayName = "Claude Code"
    let icon: ProviderIcon = .claude
    let dashboardURL = URL(string: "https://claude.ai/settings/usage")

    private let client = ClaudeOAuthClient()

    func loadSnapshotSync() -> UsageSnapshot {
        let status = client.fetchStatus()
        switch status {
        case .ok(let snapshot):
            var windows: [UsageWindow] = []
            if let five = snapshot.fiveHour {
                windows.append(UsageWindow(
                    title: "5-hour window",
                    resetsAt: five.resetsAt,
                    usedPercent: five.usedPercent,
                    deltaPercent: nil,
                    isPrimary: true
                ))
            }
            if let weekly = snapshot.sevenDay {
                windows.append(UsageWindow(
                    title: "Weekly window",
                    resetsAt: weekly.resetsAt,
                    usedPercent: weekly.usedPercent,
                    deltaPercent: nil,
                    isPrimary: false
                ))
            }
            if let opus = snapshot.sevenDayOpus {
                windows.append(UsageWindow(
                    title: "Weekly · Opus",
                    resetsAt: opus.resetsAt,
                    usedPercent: opus.usedPercent,
                    deltaPercent: nil,
                    isPrimary: false
                ))
            }
            return UsageSnapshot(
                windows: windows,
                extras: [],
                footerText: nil,
                observedAt: snapshot.observedAt,
                inlineMessage: nil
            )
        default:
            return UsageSnapshot(
                windows: [], extras: [], footerText: nil, observedAt: nil,
                inlineMessage: status.menuMessage
            )
        }
    }
}
