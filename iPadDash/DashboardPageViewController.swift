import UIKit

/// Posted by a page when its `alerts` change.
let pageAlertDidChange = Notification.Name("PageAlertDidChange")

/// Something a page draws in red, as listed on the summary page: "Service down" · "cams".
struct PageAlert: Equatable {
    let what: String
    let detail: String
    /// A fetch that failed for lack of network; the summary page leaves these out
    /// while it shows "No network".
    var offline = false
    init(_ what: String, _ detail: String = "") {
        self.what = what
        self.detail = detail
    }

    /// A failed fetch: "Cluster" · "The Internet connection appears to be offline."
    init(_ what: String, error: Error) {
        self.init(what, error.localizedDescription)
        let networkCodes: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                                             .internationalRoamingOff, .dataNotAllowed]
        offline = (error as? URLError).map { networkCodes.contains($0.code) } ?? false
    }
}

/// A US-English formatter for a fixed date format.
func makeDateFormatter(_ format: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.dateFormat = format
    return f
}

let timeOfDayFormatter = makeDateFormatter("h:mm a")

/// A swipeable dashboard page: fetches on a timer and on demand, and shows the
/// result under a title bar. Subclasses build their views, call `startFetching()`
/// at the end of `viewDidLoad`, and override `load(completion:)` and `render()`.
class DashboardPageViewController: UIViewController {
    /// Everything on the page drawn in red (a red page dot, and rows on the summary page).
    var alerts: [PageAlert] = [] {
        didSet {
            if alerts != oldValue { NotificationCenter.default.post(name: pageAlertDidChange, object: nil) }
        }
    }
    var hasAlert: Bool { return !alerts.isEmpty }
    /// Set by a page that joins the rotation, the page dots and the summary page's
    /// list of names only while it has red items (or is showing).
    var onlyWhenRed: Bool { return false }
    /// The page's name as in its title bar, without the detail after " · ".
    private(set) var pageName = ""
    /// Right side of the title bar: last update, or what went wrong.
    let instanceLabel = SpacedLabel(font: font(16))
    private(set) var fetching = false
    /// When the last attempt finished, successful or not.
    private(set) var lastFetch: Date?
    private var fetchTimer: Timer?
    /// Set once the page shows `showStatus` in its title bar (so "refreshing…" fits there).
    private var usesStatusLine = false

    /// Set by a page that ignores the update interval setting.
    var fixedFetchInterval: TimeInterval? { return nil }
    /// Set by a page whose text depends on the clock, to redraw between fetches.
    var redrawInterval: TimeInterval? { return nil }

    /// Fetch and store the page's data, then call `completion` on the main queue.
    func load(completion: @escaping () -> Void) { completion() }
    @objc func render() {}

    override func loadView() {
        view = PaperView()
    }

    func startFetching() {
        if fixedFetchInterval == nil {
            NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                                   name: Settings.didChange, object: nil)
        }
        if let interval = redrawInterval {
            Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.render()
            }
        }
        render()
        // Start right away, even before the page is shown, so its dot can turn red.
        fetch()
        startFetchTimer()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard fixedFetchInterval == nil else { return }
        // Catch up after being off screen (another page, the Settings page) longer than an interval.
        if lastFetch.map({ Date().timeIntervalSince($0) >= Settings.refreshInterval }) ?? true {
            fetch()
        }
        startFetchTimer()
    }

    /// Fetch fresh data for everything on the page now (tap and swipe up);
    /// the next automatic update is a full interval from now.
    func reloadNow() {
        fetch()
        startFetchTimer()
    }

    /// Any setting changed; only a new update interval restarts the timer.
    @objc private func settingsChanged() {
        if fetchTimer?.timeInterval != Settings.refreshInterval { startFetchTimer() }
    }

    private func startFetchTimer() {
        fetchTimer?.invalidate()
        fetchTimer = Timer.scheduledTimer(withTimeInterval: fixedFetchInterval ?? Settings.refreshInterval,
                                          repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    private func fetch() {
        guard !fetching else { return }
        fetching = true
        // A full render only the first time ("loading…"); after that just the status line.
        if lastFetch == nil {
            render()
        } else if usesStatusLine {
            instanceLabel.set("refreshing…")
        }
        load {
            self.fetching = false
            self.lastFetch = Date()
            self.render()
        }
    }

    /// The headline under the page title, and the dimmed line under it (see `addHeader`).
    private(set) lazy var heroLabel = SpacedLabel(font: font(36, .heavy))
    private(set) lazy var summaryLabel = SpacedLabel(font: font(16), alpha: 0.6)

    /// Adds the page title ("GITHUB") centered at the top, `heroLabel` under it, and
    /// under that `subtitle` (`summaryLabel` unless given). Returns the subtitle, for
    /// the page's content to follow.
    @discardableResult
    func addHeader(_ title: String, subtitle: UIView? = nil, subtitleSpacing: CGFloat = 6) -> UIView {
        let titleLabel = SpacedLabel(font: font(26, .bold), kern: 2, uppercase: true)
        titleLabel.set(title)
        let subtitle = subtitle ?? summaryLabel
        for v in [titleLabel, heroLabel, subtitle] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 26),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            heroLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            heroLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            heroLabel.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 24),
            subtitle.topAnchor.constraint(equalTo: heroLabel.bottomAnchor, constant: subtitleSpacing),
            subtitle.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
        return subtitle
    }

    /// The TRMNL-style top half: two equal panels with a divider between them and
    /// the title bar below, ending at the middle of the screen.
    func addPanels(_ left: UIView, _ right: UIView, title: String) -> (rule: UIView, bar: UIView) {
        let divider = InkView()
        let columns = UIStackView(arrangedSubviews: [left, divider, right])
        columns.alignment = .fill
        let (rule, bar) = addTitleBar(title)
        columns.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(columns)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 2),
            left.widthAnchor.constraint(equalTo: right.widthAnchor),
            columns.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            columns.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
            columns.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8),
            rule.topAnchor.constraint(equalTo: columns.bottomAnchor, constant: 8),
            bar.bottomAnchor.constraint(equalTo: view.centerYAnchor, constant: -8),
        ])
        return (rule, bar)
    }

    /// Adds the rule and the title bar (name on the left, `instanceLabel` on the
    /// right) with their side margins. The page places them vertically.
    func addTitleBar(_ name: String) -> (rule: UIView, bar: UIView) {
        pageName = name.components(separatedBy: " · ")[0]
        let rule = InkView()
        let titleLabel = SpacedLabel(font: font(16, .bold))
        titleLabel.textAlignment = .left
        titleLabel.set(name)
        instanceLabel.textAlignment = .right
        let bar = UIStackView(arrangedSubviews: [titleLabel, instanceLabel])
        for v in [rule, bar] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            rule.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            rule.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            rule.heightAnchor.constraint(equalToConstant: 2),
            bar.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: rule.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: rule.trailingAnchor),
        ])
        return (rule, bar)
    }

    /// "refreshing…", "fetch failed: … · updated …" over older data, or just `updated`
    /// (by default the time of the last attempt).
    func showStatus(error: Error?, hasData: Bool, updated: String? = nil) {
        usesStatusLine = true
        let updated = updated ?? lastFetch.map { "updated \(timeOfDayFormatter.string(from: $0))" } ?? ""
        if fetching {
            instanceLabel.set("refreshing…")
        } else if let error = error, hasData {
            instanceLabel.set("fetch failed: \(error.localizedDescription) · " + updated)
        } else {
            instanceLabel.set(updated)
        }
    }
}
