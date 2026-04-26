import Foundation

final class CodexTokenReader {
    func tokenActivitySummary(recentWindowSeconds: TimeInterval = 180) -> TokenActivitySummary {
        let sessions = tokenSessionScans()
        guard !sessions.isEmpty else {
            return .empty(recentWindowSeconds: recentWindowSeconds)
        }

        let allEvents = sessions.flatMap(\.tokenEvents)
        let latestEvent = allEvents.max { lhs, rhs in
            if lhs.observedAt == rhs.observedAt {
                return lhs.sequence < rhs.sequence
            }
            return lhs.observedAt < rhs.observedAt
        }

        let latestTask = sessions.flatMap { session in
            session.taskStarts.map { (source: session.source, startedAt: $0) }
        }.max { lhs, rhs in
            lhs.startedAt < rhs.startedAt
        }

        let latestTurnUsage: TokenUsage?
        if let latestTask,
           let session = sessions.first(where: { $0.source == latestTask.source }) {
            latestTurnUsage = turnUsage(in: session, startedAt: latestTask.startedAt)
        } else {
            latestTurnUsage = nil
        }

        return TokenActivitySummary(
            latestCallUsage: latestEvent?.lastUsage,
            latestTurnUsage: latestTurnUsage,
            recentUsage: recentUsage(in: sessions, recentWindowSeconds: recentWindowSeconds),
            recentWindowSeconds: recentWindowSeconds
        )
    }

    private func tokenSessionScans() -> [TokenSessionScan] {
        guard let enumerator = FileManager.default.enumerator(
            at: CodexPaths.sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidates: [(url: URL, modifiedAt: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            candidates.append((url, values?.contentModificationDate ?? .distantPast))
        }

        return candidates
            .sorted(by: { $0.modifiedAt > $1.modifiedAt })
            .prefix(12)
            .compactMap { scanTokenSessionTail(of: $0.url) }
    }

    private func scanTokenSessionTail(of url: URL) -> TokenSessionScan? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let maxBytes: UInt64 = 2 * 1024 * 1024
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let offset = fileSize > maxBytes ? fileSize - maxBytes : 0
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var sequence = 0
        var taskStarts: [Date] = []
        var tokenEvents: [TokenUsageEvent] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            sequence += 1
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let timestamp = DateParsing.parseISO8601(object["timestamp"] as? String),
                  let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String else {
                continue
            }

            if payloadType == "task_started" {
                taskStarts.append(timestamp)
                continue
            }

            guard payloadType == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any] else {
                continue
            }

            tokenEvents.append(TokenUsageEvent(
                source: url.path,
                observedAt: timestamp,
                sequence: sequence,
                totalUsage: tokenUsage(total),
                lastUsage: tokenUsage(last)
            ))
        }

        guard !taskStarts.isEmpty || !tokenEvents.isEmpty else { return nil }
        return TokenSessionScan(source: url.path, taskStarts: taskStarts, tokenEvents: tokenEvents)
    }

    private func turnUsage(in session: TokenSessionScan, startedAt: Date) -> TokenUsage? {
        let events = session.tokenEvents.sorted {
            if $0.observedAt == $1.observedAt {
                return $0.sequence < $1.sequence
            }
            return $0.observedAt < $1.observedAt
        }

        guard let latestAfterStart = events.last(where: { $0.observedAt >= startedAt }) else {
            return nil
        }

        if let previousBeforeStart = events.last(where: { $0.observedAt < startedAt }) {
            return latestAfterStart.totalUsage.delta(from: previousBeforeStart.totalUsage)
        }

        if let firstAfterStart = events.first(where: { $0.observedAt >= startedAt }),
           firstAfterStart.sequence != latestAfterStart.sequence {
            return latestAfterStart.totalUsage.delta(from: firstAfterStart.totalUsage)
        }

        return latestAfterStart.lastUsage
    }

    private func recentUsage(in sessions: [TokenSessionScan], recentWindowSeconds: TimeInterval) -> TokenUsage {
        let cutoff = Date().addingTimeInterval(-recentWindowSeconds)
        var total = TokenUsage.zero

        for session in sessions {
            let events = session.tokenEvents.sorted {
                if $0.observedAt == $1.observedAt {
                    return $0.sequence < $1.sequence
                }
                return $0.observedAt < $1.observedAt
            }
            var previous: TokenUsage?

            for event in events {
                defer { previous = event.totalUsage }

                guard event.observedAt >= cutoff,
                      let previous else {
                    continue
                }

                let delta = event.totalUsage.delta(from: previous)
                guard delta.totalTokens > 0 else { continue }
                total = total.adding(delta)
            }
        }

        return total
    }

    private func tokenUsage(_ value: [String: Any]) -> TokenUsage {
        TokenUsage(
            inputTokens: NumberParsing.int64(value["input_tokens"]),
            cachedInputTokens: NumberParsing.int64(value["cached_input_tokens"]),
            outputTokens: NumberParsing.int64(value["output_tokens"]),
            reasoningOutputTokens: NumberParsing.int64(value["reasoning_output_tokens"]),
            totalTokens: NumberParsing.int64(value["total_tokens"])
        )
    }
}
