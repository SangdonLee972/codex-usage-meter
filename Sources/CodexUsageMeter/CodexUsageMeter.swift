import AppKit
import Foundation

enum AppInfo {
    static let version = "0.4.0"
    static let repoOwner = "SangdonLee972"
    static let repoName = "codex-usage-meter"
}

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
        guard let previousUsed else {
            return nil
        }
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

final class UsageReader {
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let decoder = ISO8601DateFormatter()

    init() {
        decoder.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func latestSnapshot() -> RateLimitSnapshot? {
        latestSnapshotHistory()?.latest
    }

    func latestSnapshotHistory() -> UsageSnapshotHistory? {
        let sessionsRoot = home.appendingPathComponent(".codex/sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
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
        guard let latest = sorted.first else {
            return nil
        }

        let previousDistinct = sorted.dropFirst().first { previous in
            abs(previous.primaryUsedPercent - latest.primaryUsedPercent) >= 0.01 ||
                abs(previous.secondaryUsedPercent - latest.secondaryUsedPercent) >= 0.01
        }

        return UsageSnapshotHistory(latest: latest, previousDistinct: previousDistinct)
    }

    func localTokenStats() -> LocalTokenStats {
        let db = home.appendingPathComponent(".codex/state_5.sqlite").path
        let query = """
        select \
        coalesce(sum(case when created_at >= strftime('%s','now','-5 hours') then tokens_used else 0 end),0), \
        coalesce(sum(case when date(created_at,'unixepoch','localtime') = date('now','localtime') then tokens_used else 0 end),0), \
        coalesce(sum(tokens_used),0) \
        from threads;
        """

        let output = run("/usr/bin/sqlite3", arguments: ["-separator", "|", db, query])
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
        guard parts.count == 3 else {
            return LocalTokenStats(lastFiveHours: nil, today: nil, total: nil)
        }
        return LocalTokenStats(
            lastFiveHours: Int64(parts[0]),
            today: Int64(parts[1]),
            total: Int64(parts[2])
        )
    }

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
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }

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
                observedAt: parseDate(object["timestamp"] as? String) ?? Date.distantPast,
                planType: rateLimits["plan_type"] as? String ?? "unknown",
                primaryUsedPercent: number(primary["used_percent"]),
                primaryResetsAt: epochDate(primary["resets_at"]),
                secondaryUsedPercent: number(secondary["used_percent"]),
                secondaryResetsAt: epochDate(secondary["resets_at"]),
                credits: stringify(rateLimits["credits"]),
                reachedType: rateLimits["rate_limit_reached_type"] as? String
            ))

            if snapshots.count >= maxSnapshots {
                break
            }
        }

        return snapshots
    }

    private func tokenSessionScans() -> [TokenSessionScan] {
        let sessionsRoot = home.appendingPathComponent(".codex/sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
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
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        let maxBytes: UInt64 = 2 * 1024 * 1024
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let offset = fileSize > maxBytes ? fileSize - maxBytes : 0
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        var sequence = 0
        var taskStarts: [Date] = []
        var tokenEvents: [TokenUsageEvent] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            sequence += 1
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let timestamp = parseDate(object["timestamp"] as? String),
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

        guard !taskStarts.isEmpty || !tokenEvents.isEmpty else {
            return nil
        }

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
                guard delta.totalTokens > 0 else {
                    continue
                }
                total = total.adding(delta)
            }
        }

        return total
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else {
            return nil
        }
        if let date = decoder.date(from: value) {
            return date
        }
        let fallback = ISO8601DateFormatter()
        return fallback.date(from: value)
    }

    private func epochDate(_ value: Any?) -> Date? {
        let seconds = number(value)
        guard seconds > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private func number(_ value: Any?) -> Double {
        if let value = value as? Double {
            return value
        }
        if let value = value as? Int {
            return Double(value)
        }
        if let value = value as? String {
            return Double(value) ?? 0
        }
        return 0
    }

    private func int64(_ value: Any?) -> Int64 {
        if let value = value as? Int64 {
            return value
        }
        if let value = value as? Int {
            return Int64(value)
        }
        if let value = value as? Double {
            return Int64(value)
        }
        if let value = value as? String {
            return Int64(value) ?? 0
        }
        return 0
    }

    private func tokenUsage(_ value: [String: Any]) -> TokenUsage {
        TokenUsage(
            inputTokens: int64(value["input_tokens"]),
            cachedInputTokens: int64(value["cached_input_tokens"]),
            outputTokens: int64(value["output_tokens"]),
            reasoningOutputTokens: int64(value["reasoning_output_tokens"]),
            totalTokens: int64(value["total_tokens"])
        )
    }

    private func stringify(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else {
            return nil
        }
        if let value = value as? String {
            return value
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }

    private func run(_ executable: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

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

final class ClaudeUsageReader {
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let isoDecoder: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 18
        return URLSession(configuration: config)
    }()

    func latestStatus() -> ClaudeUsageStatus {
        guard let token = loadAccessToken() else {
            return .missingCredentials
        }
        return fetchUsage(accessToken: token)
    }

    private func loadAccessToken() -> String? {
        let credentialsURL = home.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: credentialsURL),
           let token = parseAccessToken(from: data) {
            return token
        }

        let raw = run("/usr/bin/security",
                      arguments: ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8) else {
            return nil
        }
        return parseAccessToken(from: data)
    }

    private func parseAccessToken(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let oauth = (object["claudeAiOauth"] as? [String: Any]) ?? object
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return nil
        }
        return token
    }

    private func fetchUsage(accessToken: String) -> ClaudeUsageStatus {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return .networkError("invalid endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var response: URLResponse?
        var error: Error?

        let task = session.dataTask(with: request) { taskData, taskResponse, taskError in
            data = taskData
            response = taskResponse
            error = taskError
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 18) == .timedOut {
            task.cancel()
            return .networkError("timeout")
        }

        if let error {
            return .networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, let payload = data else {
            return .networkError("invalid response")
        }

        switch http.statusCode {
        case 200:
            return decodeSnapshot(from: payload)
        case 401:
            return .unauthorized
        case 403:
            if let body = String(data: payload, encoding: .utf8), body.contains("user:profile") {
                return .missingScope
            }
            return .httpError(403)
        default:
            return .httpError(http.statusCode)
        }
    }

    private func decodeSnapshot(from data: Data) -> ClaudeUsageStatus {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .networkError("decode failed")
        }
        let snapshot = ClaudeUsageSnapshot(
            observedAt: Date(),
            fiveHour: window(in: object, key: "five_hour"),
            sevenDay: window(in: object, key: "seven_day"),
            sevenDayOpus: window(in: object, key: "seven_day_opus"),
            sevenDaySonnet: window(in: object, key: "seven_day_sonnet")
        )
        return .ok(snapshot)
    }

    private func window(in object: [String: Any], key: String) -> ClaudeUsageWindow? {
        guard let dict = object[key] as? [String: Any] else {
            return nil
        }
        let usedPercent = number(dict["utilization"])
        let resetsAt = parseDate(dict["resets_at"] as? String)
        return ClaudeUsageWindow(usedPercent: usedPercent, resetsAt: resetsAt)
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else {
            return nil
        }
        if let date = isoDecoder.date(from: value) {
            return date
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: value)
    }

    private func number(_ value: Any?) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) ?? 0 }
        return 0
    }

    private func run(_ executable: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

struct ReleaseInfo {
    let latestVersion: String
    let releaseURL: URL
    let publishedAt: Date?
}

enum UpdateAvailability {
    case unknown
    case current
    case available(ReleaseInfo)
}

final class ReleaseChecker {
    private let currentVersion: String
    private let cacheURL: URL
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()
    private let recheckInterval: TimeInterval = 6 * 60 * 60

    init(currentVersion: String) {
        self.currentVersion = currentVersion
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = caches.appendingPathComponent("codex-usage-meter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheURL = dir.appendingPathComponent("release-check.json")
    }

    func currentAvailability() -> UpdateAvailability {
        let cached = loadCache()
        if let cached, Date().timeIntervalSince(cached.checkedAt) < recheckInterval {
            return compare(cached.info)
        }

        if let fresh = fetchLatestRelease() {
            saveCache(info: fresh, checkedAt: Date())
            return compare(fresh)
        }

        if let cached {
            return compare(cached.info)
        }
        return .unknown
    }

    private func compare(_ info: ReleaseInfo) -> UpdateAvailability {
        if isVersion(info.latestVersion, newerThan: currentVersion) {
            return .available(info)
        }
        return .current
    }

    private func fetchLatestRelease() -> ReleaseInfo? {
        let path = "https://api.github.com/repos/\(AppInfo.repoOwner)/\(AppInfo.repoName)/releases/latest"
        guard let url = URL(string: path) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("codex-usage-meter/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseObject: URLResponse?

        let task = session.dataTask(with: request) { data, response, _ in
            responseData = data
            responseObject = response
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 15) == .timedOut {
            task.cancel()
            return nil
        }

        guard let http = responseObject as? HTTPURLResponse,
              http.statusCode == 200,
              let data = responseData,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let urlString = object["html_url"] as? String,
              let releaseURL = URL(string: urlString) else {
            return nil
        }

        let publishedAt = (object["published_at"] as? String).flatMap { iso -> Date? in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: iso)
        }

        return ReleaseInfo(
            latestVersion: stripVersionPrefix(tag),
            releaseURL: releaseURL,
            publishedAt: publishedAt
        )
    }

    private func stripVersionPrefix(_ raw: String) -> String {
        raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
    }

    private func isVersion(_ candidate: String, newerThan baseline: String) -> Bool {
        let a = parseVersion(candidate)
        let b = parseVersion(baseline)
        for index in 0..<max(a.count, b.count) {
            let av = index < a.count ? a[index] : 0
            let bv = index < b.count ? b[index] : 0
            if av != bv {
                return av > bv
            }
        }
        return false
    }

    private func parseVersion(_ raw: String) -> [Int] {
        let withoutPrefix = stripVersionPrefix(raw)
        let core = withoutPrefix.split(separator: "-").first.map(String.init) ?? withoutPrefix
        return core.split(separator: ".").compactMap { Int($0) }
    }

    private struct CacheEntry {
        let checkedAt: Date
        let info: ReleaseInfo
    }

    private func loadCache() -> CacheEntry? {
        guard let data = try? Data(contentsOf: cacheURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let checkedAt = object["checkedAt"] as? TimeInterval,
              let version = object["latestVersion"] as? String,
              let urlString = object["releaseURL"] as? String,
              let url = URL(string: urlString) else {
            return nil
        }
        let publishedAt = (object["publishedAt"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
        let info = ReleaseInfo(latestVersion: version, releaseURL: url, publishedAt: publishedAt)
        return CacheEntry(checkedAt: Date(timeIntervalSince1970: checkedAt), info: info)
    }

    private func saveCache(info: ReleaseInfo, checkedAt: Date) {
        var dict: [String: Any] = [
            "checkedAt": checkedAt.timeIntervalSince1970,
            "latestVersion": info.latestVersion,
            "releaseURL": info.releaseURL.absoluteString,
        ]
        if let publishedAt = info.publishedAt {
            dict["publishedAt"] = publishedAt.timeIntervalSince1970
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) else {
            return
        }
        try? data.write(to: cacheURL)
    }
}

enum StatusIconRenderer {
    static let size = NSSize(width: 22, height: 16)

    static func makeIcon(codex: Double?, claude: Double?) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSGraphicsContext.current?.shouldAntialias = true
        NSGraphicsContext.current?.imageInterpolation = .high

        let inset: CGFloat = 1.5
        let barWidth = size.width - 2 * inset
        let barHeight: CGFloat = 5
        let gap: CGFloat = 2
        let totalH = barHeight * 2 + gap
        let baseY = (size.height - totalH) / 2

        let topBarY = baseY + barHeight + gap
        let bottomBarY = baseY

        drawBar(x: inset, y: topBarY, width: barWidth, height: barHeight, remaining: codex)
        drawBar(x: inset, y: bottomBarY, width: barWidth, height: barHeight, remaining: claude)

        return image
    }

    private static func drawBar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, remaining: Double?) {
        let radius = height / 2
        let track = NSRect(x: x, y: y, width: width, height: height)
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        guard let remaining else {
            return
        }
        let pct = max(0, min(100, remaining))
        guard pct > 0 else {
            return
        }
        let fillWidth = max(height, width * CGFloat(pct / 100))
        let fillRect = NSRect(x: x, y: y, width: fillWidth, height: height)
        remainingStateColor(for: pct).setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
    }
}

final class SectionHeaderView: NSView {
    private let title: String

    override var isFlipped: Bool { true }

    init(title: String) {
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: 314, height: 20))
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 0.9
        ]
        title.uppercased().draw(in: NSRect(x: 14, y: 5, width: 286, height: 14), withAttributes: attrs)
    }
}

final class TokenSummaryView: NSView {
    private let columns: [(label: String, value: String)]

    override var isFlipped: Bool { true }

    init(lastTurn: String, recent: String, latestCall: String) {
        self.columns = [
            ("LAST TURN", lastTurn),
            ("LAST 3 MIN", recent),
            ("LATEST CALL", latestCall)
        ]
        super.init(frame: NSRect(x: 0, y: 0, width: 314, height: 42))
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: 0.5
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]

        let totalWidth: CGFloat = 286
        let columnWidth = totalWidth / CGFloat(columns.count)
        let leftMargin: CGFloat = 14

        for (index, column) in columns.enumerated() {
            let x = leftMargin + CGFloat(index) * columnWidth
            column.label.draw(
                in: NSRect(x: x, y: 4, width: columnWidth, height: 12),
                withAttributes: labelAttrs)
            column.value.draw(
                in: NSRect(x: x, y: 19, width: columnWidth, height: 16),
                withAttributes: valueAttrs)
        }
    }
}

final class FooterMetaView: NSView {
    private let text: String

    override var isFlipped: Bool { true }

    init(text: String) {
        self.text = text
        super.init(frame: NSRect(x: 0, y: 0, width: 314, height: 18))
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        text.draw(in: NSRect(x: 14, y: 3, width: 286, height: 13), withAttributes: attrs)
    }
}

func remainingStateLabel(for remainingPercent: Double) -> String {
    switch remainingPercent {
    case 65...:
        return "plenty"
    case 35..<65:
        return "steady"
    case 15..<35:
        return "low"
    case 0..<15:
        return "critical"
    default:
        return "empty"
    }
}

func remainingStateColor(for remainingPercent: Double) -> NSColor {
    switch remainingPercent {
    case 65...:
        return .systemGreen
    case 35..<65:
        return .systemBlue
    case 15..<35:
        return .systemOrange
    default:
        return .systemRed
    }
}

final class GaugeMenuView: NSView {
    private let title: String
    private let subtitle: String
    private let fraction: CGFloat
    private let state: String
    private let percentage: String
    private let fillColor: NSColor

    override var isFlipped: Bool {
        true
    }

    init(title: String, subtitle: String, remainingPercent: Double) {
        self.title = title
        self.subtitle = subtitle
        self.fraction = CGFloat(min(100, max(0, remainingPercent)) / 100)
        self.state = remainingStateLabel(for: remainingPercent)
        self.percentage = "\(Int(remainingPercent.rounded()))% left"
        self.fillColor = remainingStateColor(for: remainingPercent)
        super.init(frame: NSRect(x: 0, y: 0, width: 314, height: 58))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let stateAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: fillColor
        ]
        let percentageAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        title.draw(in: NSRect(x: 14, y: 7, width: 135, height: 18), withAttributes: titleAttributes)
        percentage.draw(in: NSRect(x: 159, y: 8, width: 70, height: 16), withAttributes: percentageAttributes)
        state.draw(in: NSRect(x: 232, y: 8, width: 68, height: 16), withAttributes: stateAttributes)

        let track = NSRect(x: 14, y: 29, width: 286, height: 10)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: track, xRadius: 5, yRadius: 5).fill()

        if fraction > 0 {
            let fillWidth = max(3, track.width * fraction)
            let fill = NSRect(x: track.minX, y: track.minY, width: fillWidth, height: track.height)
            fillColor.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 5, yRadius: 5).fill()
        }

        subtitle.draw(in: NSRect(x: 14, y: 42, width: 286, height: 14), withAttributes: subtitleAttributes)
    }
}

final class CodexUsageMeter: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let reader = UsageReader()
    private let claudeReader = ClaudeUsageReader()
    private let releaseChecker = ReleaseChecker(currentVersion: AppInfo.version)
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = .current
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()
    private var timer: Timer?
    private var lastHistory: UsageSnapshotHistory?
    private var tokenActivity = TokenActivitySummary.empty(recentWindowSeconds: 180)
    private var claudeStatus: ClaudeUsageStatus?
    private var updateAvailability: UpdateAvailability = .unknown

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = "Codex / Claude usage"
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        lastHistory = reader.latestSnapshotHistory()
        tokenActivity = reader.tokenActivitySummary(recentWindowSeconds: 180)
        updateStatusTitle()
        rebuildMenu()
        refreshClaudeAsync()
        refreshReleaseAsync()
    }

    private func refreshClaudeAsync() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let status = self.claudeReader.latestStatus()
            DispatchQueue.main.async {
                self.claudeStatus = status
                self.updateStatusTitle()
                self.rebuildMenu()
            }
        }
    }

    private func refreshReleaseAsync() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            let availability = self.releaseChecker.currentAvailability()
            DispatchQueue.main.async {
                self.updateAvailability = availability
                self.rebuildMenu()
            }
        }
    }

    private func updateStatusTitle() {
        let codex = codexFiveHourRemaining()
        let claude = claudeFiveHourRemaining()

        statusItem.button?.image = StatusIconRenderer.makeIcon(codex: codex, claude: claude)
        statusItem.button?.image?.isTemplate = false
        statusItem.button?.toolTip = tooltipFor(codex: codex, claude: claude)
    }

    private func codexFiveHourRemaining() -> Double? {
        guard let snapshot = lastHistory?.latest else {
            return nil
        }
        if let reached = snapshot.reachedType, !reached.isEmpty {
            return 0
        }
        return max(0, 100 - snapshot.primaryUsedPercent)
    }

    private func claudeFiveHourRemaining() -> Double? {
        guard let fiveHour = claudeStatus?.snapshot?.fiveHour else {
            return nil
        }
        return max(0, 100 - fiveHour.usedPercent)
    }

    private func tooltipFor(codex: Double?, claude: Double?) -> String {
        var lines: [String] = []
        if let codex {
            lines.append("Codex 5h: \(Int(codex.rounded()))% left")
        } else {
            lines.append("Codex: no snapshot")
        }
        if let claude {
            lines.append("Claude 5h: \(Int(claude.rounded()))% left")
        } else if let message = claudeStatus?.menuMessage {
            lines.append("Claude: \(message)")
        } else {
            lines.append("Claude: loading…")
        }
        return lines.joined(separator: "\n")
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(disabled("Codex Usage Meter v\(AppInfo.version)"))
        appendUpdateNoticeIfNeeded(to: menu)
        menu.addItem(NSMenuItem.separator())

        appendCodexSection(to: menu)
        menu.addItem(NSMenuItem.separator())
        appendClaudeSection(to: menu)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(action("Refresh Now", selector: #selector(refreshFromMenu)))
        menu.addItem(action("Open Codex Dashboard", selector: #selector(openCodexDashboard)))
        menu.addItem(action("Open Claude Dashboard", selector: #selector(openClaudeDashboard)))
        menu.addItem(action("Quit", selector: #selector(quit)))
        statusItem.menu = menu
    }

    private func appendUpdateNoticeIfNeeded(to menu: NSMenu) {
        guard case .available(let info) = updateAvailability else {
            return
        }
        let item = NSMenuItem(
            title: "Update available: v\(info.latestVersion)",
            action: #selector(openLatestRelease),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
    }

    private func appendCodexSection(to menu: NSMenu) {
        menu.addItem(sectionHeader("Codex"))
        guard let history = lastHistory else {
            menu.addItem(disabled("No rate-limit snapshot found"))
            menu.addItem(disabled("Open Codex once, then refresh."))
            return
        }

        let snapshot = history.latest
        let primaryRemaining = max(0, 100 - snapshot.primaryUsedPercent)
        let secondaryRemaining = max(0, 100 - snapshot.secondaryUsedPercent)

        menu.addItem(gauge(
            title: "5-hour window",
            subtitle: gaugeSubtitle(reset: snapshot.primaryResetsAt, delta: history.primaryLeftDelta),
            remainingPercent: primaryRemaining
        ))
        menu.addItem(gauge(
            title: "Weekly window",
            subtitle: gaugeSubtitle(reset: snapshot.secondaryResetsAt, delta: history.secondaryLeftDelta),
            remainingPercent: secondaryRemaining
        ))
        menu.addItem(tokenSummary(
            lastTurn: formatTokenUsage(tokenActivity.latestTurnUsage),
            recent: formatTokenUsage(tokenActivity.recentUsage),
            latestCall: formatTokenUsage(tokenActivity.latestCallUsage)
        ))
        menu.addItem(footer(codexFooterText(snapshot: snapshot)))
    }

    private func appendClaudeSection(to menu: NSMenu) {
        menu.addItem(sectionHeader("Claude Code"))
        guard let status = claudeStatus else {
            menu.addItem(footer("Loading…"))
            return
        }

        switch status {
        case .ok(let snapshot):
            if let fiveHour = snapshot.fiveHour {
                menu.addItem(gauge(
                    title: "5-hour window",
                    subtitle: gaugeSubtitle(reset: fiveHour.resetsAt, delta: nil),
                    remainingPercent: max(0, 100 - fiveHour.usedPercent)
                ))
            }
            if let weekly = snapshot.sevenDay {
                menu.addItem(gauge(
                    title: "Weekly window",
                    subtitle: gaugeSubtitle(reset: weekly.resetsAt, delta: nil),
                    remainingPercent: max(0, 100 - weekly.usedPercent)
                ))
            }
            if let opus = snapshot.sevenDayOpus {
                menu.addItem(gauge(
                    title: "Weekly · Opus",
                    subtitle: gaugeSubtitle(reset: opus.resetsAt, delta: nil),
                    remainingPercent: max(0, 100 - opus.usedPercent)
                ))
            }
            menu.addItem(footer("Updated \(formatter.string(from: snapshot.observedAt))"))
        default:
            if let message = status.menuMessage {
                menu.addItem(footer(message))
            }
        }
    }

    private func gaugeSubtitle(reset: Date?, delta: Double?) -> String {
        var parts: [String] = ["Resets \(formatDate(reset))"]
        if let delta, abs(delta) >= 0.01 {
            let sign = delta > 0 ? "+" : ""
            let value = delta.rounded() == delta
                ? "\(sign)\(Int(delta))%"
                : "\(sign)\(String(format: "%.1f", delta))%"
            parts.append("\(value) since last")
        }
        return parts.joined(separator: " · ")
    }

    private func codexFooterText(snapshot: RateLimitSnapshot) -> String {
        var parts: [String] = ["Plan \(snapshot.planType)"]
        if let reached = snapshot.reachedType, !reached.isEmpty {
            parts.append("Limit: \(reached)")
        }
        parts.append("Updated \(formatter.string(from: snapshot.observedAt))")
        return parts.joined(separator: " · ")
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = SectionHeaderView(title: title)
        return item
    }

    private func tokenSummary(lastTurn: String, recent: String, latestCall: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = TokenSummaryView(lastTurn: lastTurn, recent: recent, latestCall: latestCall)
        return item
    }

    private func footer(_ text: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = FooterMetaView(text: text)
        return item
    }

    private func gauge(title: String, subtitle: String, remainingPercent: Double) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = GaugeMenuView(title: title, subtitle: subtitle, remainingPercent: remainingPercent)
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func refreshFromMenu() {
        refresh()
    }

    @objc private func openCodexDashboard() {
        if let url = URL(string: "https://chatgpt.com/codex/settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openClaudeDashboard() {
        if let url = URL(string: "https://claude.ai/settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openLatestRelease() {
        guard case .available(let info) = updateAvailability else {
            return
        }
        NSWorkspace.shared.open(info.releaseURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date else {
            return "unknown"
        }
        return formatter.string(from: date)
    }

    private func formatTokenUsage(_ usage: TokenUsage?) -> String {
        guard let usage else {
            return "unknown"
        }
        guard usage.totalTokens > 0 else {
            return "0 total"
        }

        return "\(formatTokenCount(usage.totalTokens)) total (out \(formatTokenCount(usage.outputTokens)))"
    }

    private func formatTokenCount(_ value: Int64) -> String {
        let absolute = Double(abs(value))
        let sign = value < 0 ? "-" : ""

        switch absolute {
        case 1_000_000_000...:
            return "\(sign)\(String(format: "%.2f", absolute / 1_000_000_000))B"
        case 1_000_000...:
            return "\(sign)\(String(format: "%.1f", absolute / 1_000_000))M"
        case 1_000...:
            return "\(sign)\(String(format: "%.1f", absolute / 1_000))K"
        default:
            return "\(value)"
        }
    }
}

@main
struct Main {
    private static var delegate: CodexUsageMeter?

    static func main() {
        if CommandLine.arguments.contains("--print") {
            printStatus()
            return
        }

        let app = NSApplication.shared
        let delegate = CodexUsageMeter()
        Main.delegate = delegate
        app.delegate = delegate
        app.run()
    }

    private static func printStatus() {
        let reader = UsageReader()
        let claudeReader = ClaudeUsageReader()
        let claudeStatus = claudeReader.latestStatus()

        guard let history = reader.latestSnapshotHistory() else {
            print("Cdx ?: no Codex rate-limit snapshot found")
            printClaudeLine(status: claudeStatus)
            return
        }

        let snapshot = history.latest
        let stats = reader.localTokenStats()
        let tokenActivity = reader.tokenActivitySummary(recentWindowSeconds: 180)
        let primaryLeft = max(0, 100 - snapshot.primaryUsedPercent)
        let weeklyLeft = max(0, 100 - snapshot.secondaryUsedPercent)
        let resetFormatter = DateFormatter()
        resetFormatter.locale = Locale.current
        resetFormatter.timeZone = .current
        resetFormatter.dateFormat = "yyyy-MM-dd HH:mm z"

        let primaryReset = snapshot.primaryResetsAt.map { resetFormatter.string(from: $0) } ?? "unknown"
        let weeklyReset = snapshot.secondaryResetsAt.map { resetFormatter.string(from: $0) } ?? "unknown"
        let todayTokens = stats.today.map(formatTokenCountForConsole) ?? "unknown"
        let primaryDelta = formatDeltaForConsole(history.primaryLeftDelta, label: "5h")
        let weeklyDelta = formatDeltaForConsole(history.secondaryLeftDelta, label: "weekly")
        let latestTurn = formatUsageForConsole(tokenActivity.latestTurnUsage)
        let recent = formatUsageForConsole(tokenActivity.recentUsage)
        let latestCall = formatUsageForConsole(tokenActivity.latestCallUsage)

        print("Cdx \(Int(primaryLeft.rounded()))% left | weekly \(Int(weeklyLeft.rounded()))% left | last change \(primaryDelta), \(weeklyDelta) | last turn \(latestTurn) | 3m \(recent) | latest call \(latestCall) | 5h reset \(primaryReset) | weekly reset \(weeklyReset) | local today \(todayTokens)")
        printClaudeLine(status: claudeStatus, resetFormatter: resetFormatter)
    }

    private static func printClaudeLine(status: ClaudeUsageStatus,
                                        resetFormatter: DateFormatter? = nil) {
        switch status {
        case .ok(let snapshot):
            let formatter: DateFormatter = resetFormatter ?? {
                let f = DateFormatter()
                f.locale = Locale.current
                f.timeZone = .current
                f.dateFormat = "yyyy-MM-dd HH:mm z"
                return f
            }()
            var parts: [String] = []
            if let fiveHour = snapshot.fiveHour {
                let left = Int(max(0, 100 - fiveHour.usedPercent).rounded())
                let reset = fiveHour.resetsAt.map { formatter.string(from: $0) } ?? "unknown"
                parts.append("Cld 5h \(left)% left (reset \(reset))")
            }
            if let weekly = snapshot.sevenDay {
                let left = Int(max(0, 100 - weekly.usedPercent).rounded())
                let reset = weekly.resetsAt.map { formatter.string(from: $0) } ?? "unknown"
                parts.append("weekly \(left)% left (reset \(reset))")
            }
            if let opus = snapshot.sevenDayOpus {
                let left = Int(max(0, 100 - opus.usedPercent).rounded())
                parts.append("opus \(left)% left")
            }
            if parts.isEmpty {
                print("Cld ?: no Claude usage windows in response")
            } else {
                print(parts.joined(separator: " | "))
            }
        case .missingCredentials, .missingScope, .unauthorized, .httpError, .networkError:
            if let message = status.menuMessage {
                print("Cld ?: \(message)")
            }
        }
    }

    private static func formatDeltaForConsole(_ delta: Double?, label: String) -> String {
        guard let delta else {
            return "\(label) unknown"
        }
        if abs(delta) < 0.01 {
            return "\(label) no change"
        }

        let sign = delta > 0 ? "+" : ""
        let value = delta.rounded() == delta ? "\(Int(delta))%" : String(format: "%.1f%%", delta)
        return "\(label) \(sign)\(value) left"
    }

    private static func formatUsageForConsole(_ usage: TokenUsage?) -> String {
        guard let usage else {
            return "unknown"
        }
        guard usage.totalTokens > 0 else {
            return "0 total"
        }

        return "\(formatTokenCountForConsole(usage.totalTokens)) total (in \(formatTokenCountForConsole(usage.inputTokens)), out \(formatTokenCountForConsole(usage.outputTokens)))"
    }

    private static func formatTokenCountForConsole(_ value: Int64) -> String {
        let absolute = Double(abs(value))
        let sign = value < 0 ? "-" : ""

        switch absolute {
        case 1_000_000_000...:
            return "\(sign)\(String(format: "%.2f", absolute / 1_000_000_000))B"
        case 1_000_000...:
            return "\(sign)\(String(format: "%.1f", absolute / 1_000_000))M"
        case 1_000...:
            return "\(sign)\(String(format: "%.1f", absolute / 1_000))K"
        default:
            return "\(value)"
        }
    }
}
