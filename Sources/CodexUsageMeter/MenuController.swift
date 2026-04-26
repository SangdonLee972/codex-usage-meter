import AppKit
import Foundation

final class MenuController: NSObject, NSApplicationDelegate {
    /// Add a new provider here and it shows up in the menu, status bar, and CLI
    /// automatically. No other file needs to change.
    private let providers: [UsageProvider] = [
        CodexProvider(),
        ClaudeProvider()
    ]

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let releaseChecker = ReleaseChecker(currentVersion: AppInfo.version)
    private let updater = Updater()
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = .current
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()
    private var timer: Timer?
    private var snapshots: [ProviderID: UsageSnapshot] = [:]
    private var updateAvailability: UpdateAvailability = .unknown

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = "Usage meter"
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.updater.reportPreviousFailureIfAny()
        }
    }

    private func refresh() {
        for provider in providers {
            provider.loadSnapshot { [weak self] snapshot in
                DispatchQueue.main.async {
                    self?.snapshots[provider.id] = snapshot
                    self?.updateStatusBar()
                    self?.rebuildMenu()
                }
            }
        }
        refreshReleaseAsync()
        updateStatusBar()
        rebuildMenu()
    }

    private func refreshReleaseAsync() {
        guard Preferences.autoUpdateCheckEnabled else { return }
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            let availability = self.releaseChecker.currentAvailability()
            DispatchQueue.main.async {
                self.updateAvailability = availability
                self.rebuildMenu()
            }
        }
    }

    // MARK: - Status bar

    private func updateStatusBar() {
        let remaining = providers.map { snapshots[$0.id]?.primaryRemainingPercent }
        statusItem.button?.image = StatusIconRenderer.makeIcon(remaining: remaining)
        statusItem.button?.image?.isTemplate = false
        statusItem.button?.toolTip = tooltip()
    }

    private func tooltip() -> String {
        providers.map { provider in
            guard let snapshot = snapshots[provider.id] else {
                return "\(provider.displayName): loading…"
            }
            if let pct = snapshot.primaryRemainingPercent {
                return "\(provider.displayName): \(Int(pct.rounded()))% left"
            }
            return "\(provider.displayName): \(snapshot.inlineMessage ?? "unavailable")"
        }.joined(separator: "\n")
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(disabled("Codex Usage Meter v\(AppInfo.version)"))
        appendUpdateNoticeIfNeeded(to: menu)

        for (index, provider) in providers.enumerated() {
            menu.addItem(NSMenuItem.separator())
            if index == 0 {
                // first divider above provider sections is implicit via the header
            }
            appendProviderSection(provider, to: menu)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(action("Refresh Now", selector: #selector(refreshFromMenu)))
        for provider in providers where provider.dashboardURL != nil {
            let item = NSMenuItem(
                title: "Open \(provider.displayName) Dashboard",
                action: #selector(openDashboard(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = provider.id.rawValue
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        appendUpdateControls(to: menu)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(action("Quit", selector: #selector(quit)))
        statusItem.menu = menu
    }

    private func appendProviderSection(_ provider: UsageProvider, to menu: NSMenu) {
        menu.addItem(sectionHeader(provider.displayName, icon: provider.icon))
        guard let snapshot = snapshots[provider.id] else {
            menu.addItem(footer("Loading…"))
            return
        }

        if snapshot.windows.isEmpty {
            menu.addItem(footer(snapshot.inlineMessage ?? "No data"))
            return
        }

        for window in snapshot.windows {
            menu.addItem(gauge(
                title: window.title,
                subtitle: gaugeSubtitle(reset: window.resetsAt, delta: window.deltaPercent),
                remainingPercent: window.remainingPercent
            ))
        }

        for extra in snapshot.extras {
            switch extra {
            case .tokenSummary(let lastTurn, let recent, let latestCall):
                menu.addItem(tokenSummary(lastTurn: lastTurn, recent: recent, latestCall: latestCall))
            }
        }

        menu.addItem(footer(footerText(for: snapshot)))
    }

    private func footerText(for snapshot: UsageSnapshot) -> String {
        var parts: [String] = []
        if let footer = snapshot.footerText {
            parts.append(footer)
        }
        if let observed = snapshot.observedAt {
            parts.append("Updated \(formatter.string(from: observed))")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func appendUpdateControls(to menu: NSMenu) {
        let checkItem = NSMenuItem(
            title: "Check for Updates Now",
            action: #selector(checkForUpdatesNow),
            keyEquivalent: ""
        )
        checkItem.target = self
        menu.addItem(checkItem)

        let toggleItem = NSMenuItem(
            title: "Auto-check for Updates",
            action: #selector(toggleAutoUpdateCheck),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.state = Preferences.autoUpdateCheckEnabled ? .on : .off
        menu.addItem(toggleItem)

        if let lastChecked = releaseChecker.lastCheckedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            let label = formatter.localizedString(for: lastChecked, relativeTo: Date())
            menu.addItem(footer("Last checked \(label)"))
        } else {
            menu.addItem(footer("No checks yet"))
        }
    }

    private func appendUpdateNoticeIfNeeded(to menu: NSMenu) {
        guard Preferences.autoUpdateCheckEnabled,
              case .available(let info) = updateAvailability else { return }
        let item = NSMenuItem(
            title: "Install update v\(info.latestVersion)…",
            action: #selector(triggerUpdate),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
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

    // MARK: - Item factories

    private func sectionHeader(_ title: String, icon: ProviderIcon? = nil) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = SectionHeaderView(title: title, icon: icon)
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

    private func formatDate(_ date: Date?) -> String {
        guard let date else { return "unknown" }
        return formatter.string(from: date)
    }

    // MARK: - Actions

    @objc private func refreshFromMenu() {
        refresh()
    }

    @objc private func openDashboard(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = ProviderID(rawValue: raw),
              let provider = providers.first(where: { $0.id == id }),
              let url = provider.dashboardURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func triggerUpdate() {
        guard case .available(let info) = updateAvailability else { return }
        updater.performUpdate(targetVersion: info.latestVersion, releaseURL: info.releaseURL)
    }

    @objc private func checkForUpdatesNow() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let availability = self.releaseChecker.currentAvailability(forceRefresh: true)
            DispatchQueue.main.async {
                self.updateAvailability = availability
                self.rebuildMenu()
                self.presentManualCheckResult(availability)
            }
        }
    }

    @objc private func toggleAutoUpdateCheck() {
        Preferences.autoUpdateCheckEnabled = !Preferences.autoUpdateCheckEnabled
        rebuildMenu()
        if Preferences.autoUpdateCheckEnabled {
            refreshReleaseAsync()
        }
    }

    private func presentManualCheckResult(_ availability: UpdateAvailability) {
        let alert = NSAlert()
        switch availability {
        case .available(let info):
            alert.alertStyle = .informational
            alert.messageText = "Update available: v\(info.latestVersion)"
            alert.informativeText = "You're running v\(AppInfo.version). Install the new version now?"
            alert.addButton(withTitle: "Install")
            alert.addButton(withTitle: "Release Notes")
            alert.addButton(withTitle: "Later")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                updater.performUpdate(targetVersion: info.latestVersion, releaseURL: info.releaseURL)
            case .alertSecondButtonReturn:
                NSWorkspace.shared.open(info.releaseURL)
            default:
                break
            }
        case .current:
            alert.alertStyle = .informational
            alert.messageText = "You're up to date"
            alert.informativeText = "Codex Usage Meter v\(AppInfo.version) is the latest released version."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .unknown:
            alert.alertStyle = .warning
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = "Unable to reach the GitHub releases API.\nCheck your network connection and try again."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
