import Foundation

enum DateParsing {
    private static let isoWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseISO8601(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = isoWithFractional.date(from: value) { return date }
        return isoPlain.date(from: value)
    }

    static func epochDate(_ value: Any?) -> Date? {
        let seconds = NumberParsing.double(value)
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

enum NumberParsing {
    static func double(_ value: Any?) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) ?? 0 }
        return 0
    }

    static func int64(_ value: Any?) -> Int64 {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? Double { return Int64(value) }
        if let value = value as? String { return Int64(value) ?? 0 }
        return 0
    }
}

enum Shell {
    @discardableResult
    static func run(_ executable: String, arguments: [String]) -> String {
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

enum TokenFormatter {
    /// Compact menu form: "27.7K total (out 633)"
    static func menuValue(_ usage: TokenUsage?) -> String {
        guard let usage else { return "unknown" }
        guard usage.totalTokens > 0 else { return "0 total" }
        return "\(count(usage.totalTokens)) total (out \(count(usage.outputTokens)))"
    }

    /// Verbose CLI form: "27.7K total (in 27.1K, out 633)"
    static func cliValue(_ usage: TokenUsage?) -> String {
        guard let usage else { return "unknown" }
        guard usage.totalTokens > 0 else { return "0 total" }
        return "\(count(usage.totalTokens)) total (in \(count(usage.inputTokens)), out \(count(usage.outputTokens)))"
    }

    static func count(_ value: Int64) -> String {
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

enum SyncHTTP {
    struct Result {
        let data: Data?
        let response: HTTPURLResponse?
        let error: Error?
    }

    static func perform(_ request: URLRequest, timeout: TimeInterval, session: URLSession = .shared) -> Result {
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

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            return Result(data: nil, response: nil, error: nil)
        }

        return Result(data: data, response: response as? HTTPURLResponse, error: error)
    }

    static func ephemeralSession(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: config)
    }
}
