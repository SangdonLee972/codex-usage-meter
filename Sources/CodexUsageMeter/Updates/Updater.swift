import AppKit
import Foundation

final class Updater {
    enum KickoffError: LocalizedError {
        case scriptWriteFailed(String)
        case scriptLaunchFailed(String)

        var errorDescription: String? {
            switch self {
            case .scriptWriteFailed(let detail):
                return "Couldn't write update script: \(detail)"
            case .scriptLaunchFailed(let detail):
                return "Couldn't launch update script: \(detail)"
            }
        }
    }

    private let stateDir: URL
    private let sourcePathFile: URL
    private let markerFile: URL
    private let logFile: URL

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        stateDir = home.appendingPathComponent(".local/state/codex-usage-meter", isDirectory: true)
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        sourcePathFile = stateDir.appendingPathComponent("source-path")
        markerFile = stateDir.appendingPathComponent("update-in-progress")
        logFile = URL(fileURLWithPath: "/tmp/codex-usage-meter-update.log")
    }

    func performUpdate(targetVersion: String, releaseURL: URL) {
        switch presentConfirmation(targetVersion: targetVersion, releaseURL: releaseURL) {
        case .install:
            break
        case .openReleaseNotes:
            NSWorkspace.shared.open(releaseURL)
            return
        case .cancel:
            return
        }

        let repoPath: URL
        if let resolved = resolveSourceRepo() {
            repoPath = resolved
        } else if let chosen = promptForRepoLocation() {
            try? chosen.path.write(to: sourcePathFile, atomically: true, encoding: .utf8)
            repoPath = chosen
        } else {
            return
        }

        do {
            try writeMarker(targetVersion: targetVersion)
            try kickoffUpdateScript(repoPath: repoPath)
        } catch {
            try? FileManager.default.removeItem(at: markerFile)
            presentKickoffFailure(error: error, repoPath: repoPath)
            return
        }

        presentUpdateStarted()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }

    /// Called once on app launch. If a previous update attempt left a marker
    /// behind and we're still running the old version, the update almost
    /// certainly failed mid-way. Surface a recovery dialog with a log link.
    func reportPreviousFailureIfAny() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: markerFile.path),
              let mtime = attrs[.modificationDate] as? Date else {
            return
        }
        guard Date().timeIntervalSince(mtime) > 30 else {
            return
        }
        try? FileManager.default.removeItem(at: markerFile)
        presentRecoveryDialog(attemptedAt: mtime)
    }

    private func resolveSourceRepo() -> URL? {
        guard let raw = try? String(contentsOf: sourcePathFile, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: trimmed, isDirectory: true)
        return validateRepo(at: url) ? url : nil
    }

    private func validateRepo(at url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        guard fm.fileExists(atPath: url.appendingPathComponent(".git").path) else {
            return false
        }
        guard fm.fileExists(atPath: url.appendingPathComponent("scripts/install.sh").path) else {
            return false
        }
        return true
    }

    private enum ConfirmationResult {
        case install
        case openReleaseNotes
        case cancel
    }

    private func presentConfirmation(targetVersion: String, releaseURL: URL) -> ConfirmationResult {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Install v\(targetVersion)?"
        alert.informativeText = """
        The app will rebuild from your local clone and restart automatically.
        This usually takes 15–30 seconds.
        """
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .install
        case .alertSecondButtonReturn: return .openReleaseNotes
        default: return .cancel
        }
    }

    private func promptForRepoLocation() -> URL? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Source folder not found"
        alert.informativeText = """
        Codex Usage Meter can't find the codex-usage-meter folder it was installed from.
        If you moved or renamed it, locate it now to continue.
        """
        alert.addButton(withTitle: "Locate…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select your codex-usage-meter folder"
        guard panel.runModal() == .OK, let chosen = panel.url else {
            return nil
        }

        if !validateRepo(at: chosen) {
            let warn = NSAlert()
            warn.alertStyle = .warning
            warn.messageText = "That folder doesn't look right"
            warn.informativeText = """
            The folder needs to contain `.git` and `scripts/install.sh`.
            Make sure you picked the codex-usage-meter project root.
            """
            warn.addButton(withTitle: "OK")
            warn.runModal()
            return nil
        }
        return chosen
    }

    private func writeMarker(targetVersion: String) throws {
        try targetVersion.write(to: markerFile, atomically: true, encoding: .utf8)
    }

    private func kickoffUpdateScript(repoPath: URL) throws {
        let escapedRepo = shellQuote(repoPath.path)
        let escapedLog = shellQuote(logFile.path)
        let escapedMarker = shellQuote(markerFile.path)

        let script = """
        #!/bin/bash
        exec </dev/null
        exec >> \(escapedLog) 2>&1
        echo
        echo "=== codex-usage-meter update started at $(date) ==="
        cd \(escapedRepo) || { echo "cd failed"; exit 1; }
        git pull || { echo "git pull failed"; exit 2; }
        ./scripts/install.sh || { echo "install.sh failed"; exit 3; }
        rm -f \(escapedMarker)
        echo "=== update completed at $(date) ==="
        """

        let scriptURL = URL(fileURLWithPath: "/tmp/codex-usage-meter-update-\(Int(Date().timeIntervalSince1970)).sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            throw KickoffError.scriptWriteFailed(error.localizedDescription)
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", "nohup \(shellQuote(scriptURL.path)) >/dev/null 2>&1 &"]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            throw KickoffError.scriptLaunchFailed(error.localizedDescription)
        }
    }

    private func presentUpdateStarted() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Update started"
        alert.informativeText = """
        The menu bar icon will reappear once the new version is installed.

        If it doesn't come back within a minute, check the log:
        \(logFile.path)
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentKickoffFailure(error: Error, repoPath: URL) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Couldn't start the update"
        alert.informativeText = """
        \(error.localizedDescription)

        You can update manually by running:
          cd \(repoPath.path)
          git pull && ./scripts/install.sh
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Reveal Folder")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([repoPath])
        }
    }

    private func presentRecoveryDialog(attemptedAt: Date) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Last update didn't finish cleanly"
        alert.informativeText = """
        An update started at \(formatter.string(from: attemptedAt)) didn't complete.
        The previous version is still running.

        Open the log to see what happened, or try again from the menu.
        """
        alert.addButton(withTitle: "View Log")
        alert.addButton(withTitle: "Dismiss")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(logFile)
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
