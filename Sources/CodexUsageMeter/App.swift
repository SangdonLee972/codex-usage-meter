import AppKit
import Foundation

enum AppInfo {
    static let version = "0.4.2"
    static let repoOwner = "SangdonLee972"
    static let repoName = "codex-usage-meter"
}

enum Preferences {
    private static let autoUpdateKey = "autoUpdateCheckEnabled"
    private static let defaults = UserDefaults.standard

    static var autoUpdateCheckEnabled: Bool {
        get {
            if defaults.object(forKey: autoUpdateKey) == nil {
                return true
            }
            return defaults.bool(forKey: autoUpdateKey)
        }
        set {
            defaults.set(newValue, forKey: autoUpdateKey)
        }
    }
}

/// Single source of truth for which providers the app exposes. Adding a new
/// provider means: implement `UsageProvider` and append it here.
enum ProviderRegistry {
    static func makeAll() -> [UsageProvider] {
        [
            CodexProvider(),
            ClaudeProvider()
        ]
    }
}

@main
struct Main {
    private static var delegate: MenuController?

    static func main() {
        if CommandLine.arguments.contains("--print") {
            CLIPrinter.printStatus()
            return
        }

        let app = NSApplication.shared
        let delegate = MenuController()
        Main.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}

enum CLIPrinter {
    static func printStatus() {
        let providers = ProviderRegistry.makeAll()
        let resetFormatter = DateFormatter()
        resetFormatter.locale = Locale.current
        resetFormatter.timeZone = .current
        resetFormatter.dateFormat = "yyyy-MM-dd HH:mm z"

        for provider in providers {
            let snapshot = provider.loadSnapshotSync()
            print(format(provider: provider, snapshot: snapshot, dateFormatter: resetFormatter))
        }
    }

    private static func format(provider: UsageProvider,
                               snapshot: UsageSnapshot,
                               dateFormatter: DateFormatter) -> String {
        let prefix = "[\(provider.displayName)]"

        if snapshot.windows.isEmpty {
            let detail = snapshot.inlineMessage ?? "no data"
            return "\(prefix) \(detail)"
        }

        var parts: [String] = []
        for window in snapshot.windows {
            let left = Int(window.remainingPercent.rounded())
            let reset = window.resetsAt.map { dateFormatter.string(from: $0) } ?? "unknown"
            parts.append("\(window.title) \(left)% left (reset \(reset))")
        }

        for extra in snapshot.extras {
            switch extra {
            case .tokenSummary(let lastTurn, let recent, let latestCall):
                parts.append("last turn \(lastTurn)")
                parts.append("3m \(recent)")
                parts.append("latest call \(latestCall)")
            }
        }

        if let footerText = snapshot.footerText {
            parts.append(footerText)
        }
        return "\(prefix) " + parts.joined(separator: " | ")
    }
}
