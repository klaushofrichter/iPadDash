import UIKit

/// Posted by a page when its `hasAlert` changes.
let pageAlertDidChange = Notification.Name("PageAlertDidChange")

let timeOfDayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.dateFormat = "h:mm a"
    return f
}()

/// A swipeable dashboard page: fetches on a timer and on demand, and shows the
/// result under a title bar. Subclasses build their views, call `startFetching()`
/// at the end of `viewDidLoad`, and override `load(completion:)` and `render()`.
class DashboardPageViewController: UIViewController {
    /// True while anything on the page is drawn in red (shown on the page dots).
    var hasAlert = false {
        didSet {
            if hasAlert != oldValue { NotificationCenter.default.post(name: pageAlertDidChange, object: nil) }
        }
    }
    /// Right side of the title bar: last update, or what went wrong.
    let instanceLabel = SpacedLabel(font: font(16))
    private(set) var fetching = false
    /// When the last attempt finished, successful or not.
    private(set) var lastFetch: Date?
    private var fetchTimer: Timer?

    /// Set by a page that ignores the update interval setting.
    var fixedFetchInterval: TimeInterval? { return nil }
    /// Set by a page whose text depends on the clock, to redraw between fetches.
    var redrawInterval: TimeInterval? { return nil }

    /// Fetch and store the page's data, then call `completion` on the main queue.
    func load(completion: @escaping () -> Void) { completion() }
    func render() {}

    override func loadView() {
        view = PaperView()
    }

    func startFetching() {
        if fixedFetchInterval == nil {
            NotificationCenter.default.addObserver(self, selector: #selector(startFetchTimer),
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
        // Catch up after being off screen (another page, the About page) longer than an interval.
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

    @objc private func startFetchTimer() {
        fetchTimer?.invalidate()
        fetchTimer = Timer.scheduledTimer(withTimeInterval: fixedFetchInterval ?? Settings.refreshInterval,
                                          repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    private func fetch() {
        guard !fetching else { return }
        fetching = true
        render()
        load {
            self.fetching = false
            self.lastFetch = Date()
            self.render()
        }
    }

    /// Adds the rule and the title bar (name on the left, `instanceLabel` on the
    /// right) with their side margins. The page places them vertically.
    func addTitleBar(_ name: String) -> (rule: UIView, bar: UIView) {
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
