import AppKit
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

        var best: RateLimitSnapshot?
        for candidate in candidates.sorted(by: { $0.modifiedAt > $1.modifiedAt }).prefix(30) {
            guard let snapshot = snapshotFromTail(of: candidate.url) else {
                continue
            }
            if best == nil || snapshot.observedAt > best!.observedAt {
                best = snapshot
            }
        }
        return best
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

    private func snapshotFromTail(of url: URL) -> RateLimitSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        let maxBytes: UInt64 = 4 * 1024 * 1024
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let offset = fileSize > maxBytes ? fileSize - maxBytes : 0
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let rateLimits = payload["rate_limits"] as? [String: Any],
                  let primary = rateLimits["primary"] as? [String: Any],
                  let secondary = rateLimits["secondary"] as? [String: Any] else {
                continue
            }

            return RateLimitSnapshot(
                observedAt: parseDate(object["timestamp"] as? String) ?? Date.distantPast,
                planType: rateLimits["plan_type"] as? String ?? "unknown",
                primaryUsedPercent: number(primary["used_percent"]),
                primaryResetsAt: epochDate(primary["resets_at"]),
                secondaryUsedPercent: number(secondary["used_percent"]),
                secondaryResetsAt: epochDate(secondary["resets_at"]),
                credits: stringify(rateLimits["credits"]),
                reachedType: rateLimits["rate_limit_reached_type"] as? String
            )
        }

        return nil
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
        self.state = GaugeMenuView.stateLabel(for: remainingPercent)
        self.percentage = "\(Int(remainingPercent.rounded()))% left"
        self.fillColor = GaugeMenuView.color(for: remainingPercent)
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

    private static func stateLabel(for remainingPercent: Double) -> String {
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

    private static func color(for remainingPercent: Double) -> NSColor {
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
}

final class CodexUsageMeter: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let reader = UsageReader()
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = .current
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()
    private var timer: Timer?
    private var lastSnapshot: RateLimitSnapshot?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        statusItem.button?.toolTip = "Codex usage"
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        lastSnapshot = reader.latestSnapshot()
        updateStatusTitle()
        rebuildMenu()
    }

    private func updateStatusTitle() {
        guard let snapshot = lastSnapshot else {
            statusItem.button?.title = "Cdx ?"
            statusItem.button?.toolTip = "No Codex usage snapshot found"
            return
        }

        let remaining = max(0, 100 - snapshot.primaryUsedPercent)
        if let reached = snapshot.reachedType, !reached.isEmpty {
            statusItem.button?.title = "Cdx limit"
        } else {
            statusItem.button?.title = "Cdx \(Int(remaining.rounded()))%"
        }
        statusItem.button?.toolTip = "Codex 5-hour window: \(Int(remaining.rounded()))% left"
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(disabled("Codex Usage Meter"))
        menu.addItem(NSMenuItem.separator())

        if let snapshot = lastSnapshot {
            let primaryRemaining = max(0, 100 - snapshot.primaryUsedPercent)
            let secondaryRemaining = max(0, 100 - snapshot.secondaryUsedPercent)

            menu.addItem(gauge(
                title: "5-hour window",
                subtitle: "Resets \(formatDate(snapshot.primaryResetsAt))",
                remainingPercent: primaryRemaining
            ))
            menu.addItem(gauge(
                title: "Weekly window",
                subtitle: "Resets \(formatDate(snapshot.secondaryResetsAt))",
                remainingPercent: secondaryRemaining
            ))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(disabled("Plan: \(snapshot.planType)"))
            if snapshot.credits != nil {
                menu.addItem(disabled("Credits data available"))
            }
            if let reached = snapshot.reachedType, !reached.isEmpty {
                menu.addItem(disabled("Limit reached: \(reached)"))
            }
            menu.addItem(disabled("Snapshot: \(formatter.string(from: snapshot.observedAt))"))
        } else {
            menu.addItem(disabled("No rate-limit snapshot found"))
            menu.addItem(disabled("Open Codex once, then refresh."))
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(action("Refresh Now", selector: #selector(refreshFromMenu)))
        menu.addItem(action("Open Usage Dashboard", selector: #selector(openDashboard)))
        menu.addItem(action("Quit", selector: #selector(quit)))
        statusItem.menu = menu
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

    @objc private func openDashboard() {
        if let url = URL(string: "https://chatgpt.com/codex/settings/usage") {
            NSWorkspace.shared.open(url)
        }
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
        guard let snapshot = reader.latestSnapshot() else {
            print("Cdx ?: no Codex rate-limit snapshot found")
            return
        }

        let stats = reader.localTokenStats()
        let primaryLeft = max(0, 100 - snapshot.primaryUsedPercent)
        let weeklyLeft = max(0, 100 - snapshot.secondaryUsedPercent)
        let resetFormatter = DateFormatter()
        resetFormatter.locale = Locale.current
        resetFormatter.timeZone = .current
        resetFormatter.dateFormat = "yyyy-MM-dd HH:mm z"

        let primaryReset = snapshot.primaryResetsAt.map { resetFormatter.string(from: $0) } ?? "unknown"
        let weeklyReset = snapshot.secondaryResetsAt.map { resetFormatter.string(from: $0) } ?? "unknown"
        let todayTokens = stats.today.map(formatTokenCountForConsole) ?? "unknown"

        print("Cdx \(Int(primaryLeft.rounded()))% left | weekly \(Int(weeklyLeft.rounded()))% left | 5h reset \(primaryReset) | weekly reset \(weeklyReset) | local today \(todayTokens)")
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
