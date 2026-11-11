import UIKit

/// Pull request activity for the klaushofrichter account. The oldest open PRs on
/// top (red once older than a day); recent merges fill the rest of the page.
/// Updates hourly and on tap; the title bar shows the data's age in minutes.
final class GitHubPageViewController: DashboardPageViewController {
    override var fixedFetchInterval: TimeInterval? { return 3600 }
    // The age in the title bar counts in minutes.
    override var redrawInterval: TimeInterval? { return 60 }
    private let staleAfter: TimeInterval = 2 * 3600     // two missed hourly updates
    private let shownOpenPRs = 5                        // rows; more get a "plus …" line
    // Text below the subtitle is twice the size of the other pages' detail text.
    private let mergeRowHeight: CGFloat = 92

    private let service = GitHubService()
    private var snapshot: GitHubSnapshot?
    private var lastError: Error?
    private var lastSuccess: Date?

    private let openRows = UIStackView()
    private let moreOpenLabel = SpacedLabel(font: font(32), alpha: 0.6)
    private let noOpenLabel = SpacedLabel(font: font(32), alpha: 0.6)
    private lazy var mergeHeading = sectionHeading("")
    private let mergeArea = UIView()
    private let mergeRows = UIStackView()
    private let dayFormatter = makeDateFormatter("MMM d")

    override func viewDidLoad() {
        super.viewDidLoad()
        let openHeading = sectionHeading("Open pull requests, oldest first")
        openRows.axis = .vertical
        openRows.spacing = 10
        for _ in 0..<shownOpenPRs {
            let row = KeyValueRow(size: 32)
            // A long title is cut short; the age stays.
            row.keyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.keyLabel.adjustsFontSizeToFitWidth = false
            row.keyLabel.lineBreakMode = .byTruncatingTail
            row.valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.valueLabel.setContentHuggingPriority(.required, for: .horizontal)
            openRows.addArrangedSubview(row)
        }
        noOpenLabel.textAlignment = .left
        noOpenLabel.set("No open pull requests")
        openRows.insertArrangedSubview(noOpenLabel, at: 0)
        moreOpenLabel.textAlignment = .left
        openRows.addArrangedSubview(moreOpenLabel)
        mergeHeading.set("Recent merges")

        mergeRows.axis = .vertical
        mergeRows.translatesAutoresizingMaskIntoConstraints = false
        mergeArea.clipsToBounds = true
        mergeArea.addSubview(mergeRows)

        let content = addFullPage(title: "GitHub", bar: "GitHub · \(service.owner)")
        for v in [openHeading, openRows, mergeHeading, mergeArea] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        NSLayoutConstraint.activate([
            openHeading.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            openHeading.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            openRows.topAnchor.constraint(equalTo: openHeading.bottomAnchor, constant: 14),
            openRows.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            openRows.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            mergeHeading.topAnchor.constraint(equalTo: openRows.bottomAnchor, constant: 32),
            mergeHeading.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            mergeHeading.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor),
            mergeArea.topAnchor.constraint(equalTo: mergeHeading.bottomAnchor, constant: 14),
            mergeArea.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            mergeArea.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            mergeArea.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            mergeRows.topAnchor.constraint(equalTo: mergeArea.topAnchor),
            mergeRows.leadingAnchor.constraint(equalTo: mergeArea.leadingAnchor),
            mergeRows.trailingAnchor.constraint(equalTo: mergeArea.trailingAnchor),
        ])

        startFetching()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // As many merge rows as fit in the space left between the sections and the title bar.
        let capacity = max(Int(mergeArea.bounds.height / mergeRowHeight), 0)
        if capacity != mergeRows.arrangedSubviews.count {
            mergeRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for _ in 0..<capacity {
                let row = MergeRowView()
                row.heightAnchor.constraint(equalToConstant: mergeRowHeight).isActive = true
                mergeRows.addArrangedSubview(row)
            }
            render()
        }
    }

    override func load(completion: @escaping () -> Void) {
        service.fetchSnapshot { result in
            switch result {
            case .success(var snapshot):
                #if DEBUG
                // IPADDASH_GITHUB_OPEN=<n> pretends n made-up pull requests are open,
                // the oldest 3 days old.
                if let n = ProcessInfo.processInfo.environment["IPADDASH_GITHUB_OPEN"].flatMap(Int.init) {
                    snapshot = GitHubPageViewController.demo(open: n, into: snapshot)
                }
                #endif
                self.snapshot = snapshot
                self.lastError = nil
                self.lastSuccess = Date()
            case .failure(let error):
                self.lastError = error
                self.retrySoon()
            }
            completion()
        }
    }

    override func render() {
        let now = Date()
        if let s = snapshot {
            heroLabel.set(s.headline(now: now))
            // The open count stays in view when the headline names an alert instead.
            let open = s.alerts(now: now).isEmpty ? "" : "\(groupedNumber(s.openCount)) open · "
            summaryLabel.set("\(open)\(groupedNumber(s.merged24h)) merged in the last 24 h · \(groupedNumber(s.merged30d)) in 30 days")
            let recent: String
            switch s.merged24h {
            case 0: recent = "none"
            case 1: recent = "one"
            default: recent = groupedNumber(s.merged24h)
            }
            mergeHeading.set("Recent merges (\(recent) in the last 24 hours)")
            let shown = Array(s.openPRs.prefix(shownOpenPRs))
            noOpenLabel.isHidden = s.openCount > 0
            // Unused slots collapse, so the merge list below gets the space.
            openRows.showRows(shown) { (row: KeyValueRow, pr) in
                let age = now.timeIntervalSince(pr.created)
                row.set("\(pr.repo) #\(pr.number) · \(pr.title)", durationText(age),
                        alert: age > GitHubSnapshot.overdueAge)
            }
            let more = s.openCount - shown.count
            moreOpenLabel.isHidden = more <= 0
            moreOpenLabel.set("… plus \(counted(more, "other PR"))")
            mergeRows.showRows(s.recentMerges) { (row: MergeRowView, pr) in
                let when = Calendar.current.isDateInToday(pr.mergedAt)
                    ? timeOfDayFormatter.string(from: pr.mergedAt) : self.dayFormatter.string(from: pr.mergedAt)
                row.configure(when: when, repo: "\(pr.repo) #\(pr.number) → \(pr.base)", title: pr.title)
            }
        } else {
            heroLabel.set(lastError?.localizedDescription ?? "loading…")
            summaryLabel.set("")
            noOpenLabel.isHidden = true
            openRows.arrangedSubviews.forEach { $0.isHidden = true }
            mergeRows.arrangedSubviews.forEach { $0.isHidden = true }
        }
        let openAlerts = snapshot?.alerts(now: now) ?? []
        heroLabel.alert = !openAlerts.isEmpty || (snapshot == nil && lastError != nil)

        // Age of the data in minutes, counted from the last successful fetch.
        let age = lastSuccess.map { now.timeIntervalSince($0) }
        showStatus(error: lastError, hasData: snapshot != nil,
                   updated: age.map { "updated \(Int($0 / 60)) min ago" } ?? "")
        let stale = (age ?? 0) > staleAfter
        instanceLabel.alert = lastError != nil || stale
        var alerts: [PageAlert] = []
        if let error = lastError { alerts.append(PageAlert("GitHub", error: error)) }
        if stale, let age = age { alerts.append(PageAlert("GitHub data", "\(durationText(age)) old")) }
        self.alerts = alerts + openAlerts
    }

}

#if DEBUG
extension GitHubPageViewController {
    /// `snapshot` with `open` made-up pull requests, spread from 3 days to 20 minutes old.
    static func demo(open: Int, into snapshot: GitHubSnapshot, now: Date = Date()) -> GitHubSnapshot {
        var snapshot = snapshot
        let repos = ["cams", "art", "loopy-game", "cam-proxy", "kauf-server"]
        let titles = ["Weekly dependency updates", "Fix the night mode fade", "Release to production",
                      "Retry a dropped connection once", "README: setup steps"]
        snapshot.openCount = open
        snapshot.openPRs = (0..<min(open, 100)).map { i in
            let age = 3 * 86400 * pow(0.45, Double(i)) + 20 * 60
            return OpenPR(repo: repos[i % repos.count], number: 120 - i * 7,
                          title: titles[i % titles.count], created: now.addingTimeInterval(-age))
        }
        return snapshot
    }
}
#endif

/// Two lines: "12:38   traders-game #21", then the title starting under the ID,
/// one line and clipped when too long.
final class MergeRowView: UIView {
    private let whenLabel = SpacedLabel(font: font(30), alpha: 0.6)
    private let repoLabel = SpacedLabel(font: font(30, .semibold))
    private let titleLabel = SpacedLabel(font: font(30), alpha: 0.85)

    override init(frame: CGRect) {
        super.init(frame: frame)
        for label in [whenLabel, repoLabel, titleLabel] {
            label.textAlignment = .left
            label.adjustsFontSizeToFitWidth = false
            label.lineBreakMode = .byTruncatingTail
            label.numberOfLines = 1
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            whenLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            whenLabel.widthAnchor.constraint(equalToConstant: 140),
            whenLabel.firstBaselineAnchor.constraint(equalTo: repoLabel.firstBaselineAnchor),
            repoLabel.topAnchor.constraint(equalTo: topAnchor),
            repoLabel.leadingAnchor.constraint(equalTo: whenLabel.trailingAnchor, constant: 12),
            repoLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: repoLabel.bottomAnchor, constant: 2),
            titleLabel.leadingAnchor.constraint(equalTo: repoLabel.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(when: String, repo: String, title: String) {
        whenLabel.set(when)
        repoLabel.set(repo)
        titleLabel.set(title)
    }
}
