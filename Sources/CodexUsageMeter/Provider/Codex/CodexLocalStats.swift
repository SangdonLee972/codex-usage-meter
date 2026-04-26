import Foundation

enum CodexLocalStatsReader {
    static func query() -> LocalTokenStats {
        let sql = """
        select \
        coalesce(sum(case when created_at >= strftime('%s','now','-5 hours') then tokens_used else 0 end),0), \
        coalesce(sum(case when date(created_at,'unixepoch','localtime') = date('now','localtime') then tokens_used else 0 end),0), \
        coalesce(sum(tokens_used),0) \
        from threads;
        """
        let output = Shell.run("/usr/bin/sqlite3", arguments: ["-separator", "|", CodexPaths.stateDB, sql])
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
}
