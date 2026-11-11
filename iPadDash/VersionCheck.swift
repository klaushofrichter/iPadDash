import Foundation

/// Compares the installed version (set by deploy.sh, e.g. "2026.11.10.11") with the
/// latest GitHub release of this repository, once a day. Public data: no token.
final class VersionCheck {
    static let shared = VersionCheck()
    static let didChange = Notification.Name("VersionCheckDidChange")

    private let latestURL = URL(string: "https://api.github.com/repos/klaushofrichter/iPadDash/releases/latest")!
    private let interval: TimeInterval = 24 * 3600
    private var timer: Timer?

    /// The version this build carries; "dev" for a build that isn't a release.
    let installed: String = {
        #if DEBUG
        // Test aid: IPADDASH_VERSION=2026.11.1.1 pretends to be an older release.
        if let fake = ProcessInfo.processInfo.environment["IPADDASH_VERSION"] { return fake }
        #endif
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }()
    /// The latest release's version, once known.
    private(set) var latest: String?
    private(set) var lastChecked: Date?

    func start() {
        check()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.check() }
    }

    func check() {
        var request = URLRequest(url: latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        fetchJSON(request, errorKey: "message") { result in
            // A failed check changes nothing: the network has its own alerts.
            guard case .success(let json) = result, let tag = json["tag_name"] as? String else { return }
            self.latest = VersionCheck.version(fromTag: tag)
            self.lastChecked = Date()
            NotificationCenter.default.post(name: VersionCheck.didChange, object: nil)
        }
    }

    /// A newer release than the one installed; nil while unknown, up to date, or a dev build.
    var newerRelease: String? {
        guard let latest = latest, VersionCheck.isNewer(latest, than: installed) else { return nil }
        return latest
    }

    /// The red item for the summary page.
    var alert: PageAlert? {
        return newerRelease.map { PageAlert("App update", "\($0) available") }
    }

    /// "v2026.11.10.11" → "2026.11.10.11".
    static func version(fromTag tag: String) -> String {
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Compares dotted numbers part by part ("2026.11.10.11" > "2026.11.10.9").
    /// Anything that isn't such a version (a "dev" build) is never older.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        func parts(_ v: String) -> [Int]? {
            let p = v.split(separator: ".").map { Int($0) }
            return p.isEmpty || p.contains(where: { $0 == nil }) ? nil : p.compactMap { $0 }
        }
        guard let a = parts(candidate), let b = parts(installed) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
