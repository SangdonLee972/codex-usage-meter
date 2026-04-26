import Foundation

final class ClaudeOAuthClient {
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let session = SyncHTTP.ephemeralSession(requestTimeout: 12, resourceTimeout: 18)

    func fetchStatus() -> ClaudeUsageStatus {
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

        let raw = Shell.run("/usr/bin/security",
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

        let result = SyncHTTP.perform(request, timeout: 18, session: session)
        if let error = result.error {
            return .networkError(error.localizedDescription)
        }
        guard let http = result.response, let payload = result.data else {
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
        guard let dict = object[key] as? [String: Any] else { return nil }
        return ClaudeUsageWindow(
            usedPercent: NumberParsing.double(dict["utilization"]),
            resetsAt: DateParsing.parseISO8601(dict["resets_at"] as? String)
        )
    }
}
