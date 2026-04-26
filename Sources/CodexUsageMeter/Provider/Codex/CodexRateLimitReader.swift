import Foundation

final class CodexRateLimitReader {
    func latestSnapshotHistory() -> UsageSnapshotHistory? {
        guard let enumerator = FileManager.default.enumerator(
            at: CodexPaths.sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var candidates: [(url: URL, modifiedAt: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            candidates.append((url, values?.contentModificationDate ?? .distantPast))
        }

        var snapshots: [RateLimitSnapshot] = []
        for candidate in candidates.sorted(by: { $0.modifiedAt > $1.modifiedAt }).prefix(30) {
            snapshots.append(contentsOf: snapshotsFromTail(of: candidate.url, maxSnapshots: 80))
        }

        let sorted = snapshots.sorted { $0.observedAt > $1.observedAt }
        guard let latest = sorted.first else { return nil }

        let previousDistinct = sorted.dropFirst().first { previous in
            abs(previous.primaryUsedPercent - latest.primaryUsedPercent) >= 0.01 ||
                abs(previous.secondaryUsedPercent - latest.secondaryUsedPercent) >= 0.01
        }

        return UsageSnapshotHistory(latest: latest, previousDistinct: previousDistinct)
    }

    private func snapshotsFromTail(of url: URL, maxSnapshots: Int) -> [RateLimitSnapshot] {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return []
        }
        defer { try? handle.close() }

        let maxBytes: UInt64 = 4 * 1024 * 1024
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let offset = fileSize > maxBytes ? fileSize - maxBytes : 0
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var snapshots: [RateLimitSnapshot] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let rateLimits = payload["rate_limits"] as? [String: Any],
                  let primary = rateLimits["primary"] as? [String: Any],
                  let secondary = rateLimits["secondary"] as? [String: Any] else {
                continue
            }

            snapshots.append(RateLimitSnapshot(
                observedAt: DateParsing.parseISO8601(object["timestamp"] as? String) ?? .distantPast,
                planType: rateLimits["plan_type"] as? String ?? "unknown",
                primaryUsedPercent: NumberParsing.double(primary["used_percent"]),
                primaryResetsAt: DateParsing.epochDate(primary["resets_at"]),
                secondaryUsedPercent: NumberParsing.double(secondary["used_percent"]),
                secondaryResetsAt: DateParsing.epochDate(secondary["resets_at"]),
                credits: stringify(rateLimits["credits"]),
                reachedType: rateLimits["rate_limit_reached_type"] as? String
            ))

            if snapshots.count >= maxSnapshots { break }
        }
        return snapshots
    }

    private func stringify(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let value = value as? String { return value }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }
}
