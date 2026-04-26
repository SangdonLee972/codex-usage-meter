import Foundation

enum ProviderID: String, Hashable {
    case codex
    case claude
    case gemini
}

struct UsageWindow {
    let title: String
    let resetsAt: Date?
    let usedPercent: Double
    let deltaPercent: Double?
    let isPrimary: Bool

    var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }
}

enum MenuExtra {
    case tokenSummary(lastTurn: String, recent: String, latestCall: String)
}

struct UsageSnapshot {
    let windows: [UsageWindow]
    let extras: [MenuExtra]
    let footerText: String?
    let observedAt: Date?
    /// Shown in place of windows when the provider can't render gauges
    /// (e.g. "Sign in: run `claude` once").
    let inlineMessage: String?

    static let loading = UsageSnapshot(
        windows: [], extras: [], footerText: nil, observedAt: nil,
        inlineMessage: "Loading…"
    )

    var primaryRemainingPercent: Double? {
        windows.first(where: \.isPrimary)?.remainingPercent
            ?? windows.first?.remainingPercent
    }
}

protocol UsageProvider: AnyObject {
    var id: ProviderID { get }
    var displayName: String { get }
    var icon: ProviderIcon { get }
    var dashboardURL: URL? { get }

    /// Asynchronous fetch. Implementations should run off the main thread and
    /// invoke `completion` on whatever queue is convenient — the controller
    /// marshals UI updates back to main.
    func loadSnapshot(completion: @escaping (UsageSnapshot) -> Void)

    /// Synchronous fetch for CLI / one-shot use. Allowed to block.
    func loadSnapshotSync() -> UsageSnapshot
}

extension UsageProvider {
    func loadSnapshot(completion: @escaping (UsageSnapshot) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(self.loadSnapshotSync())
        }
    }
}
