import Foundation

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

    func currentAvailability(forceRefresh: Bool = false) -> UpdateAvailability {
        let cached = loadCache()
        if !forceRefresh, let cached, Date().timeIntervalSince(cached.checkedAt) < recheckInterval {
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

    var lastCheckedAt: Date? {
        loadCache()?.checkedAt
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
