import UIKit

/// Pull request activity for the klaushofrichter account. Open PRs and
/// the top repositories on top; recent merges fill the rest of the page.
/// Updates hourly and on tap; the title bar shows the data's age in minutes.
final class GitHubPageViewController: DashboardPageViewController {
    override var fixedFetchInterval: TimeInterval? { return 3600 }
    // The age in the title bar counts in minutes.
    override var redrawInterval: TimeInterval? { return 60 }
    private let staleAfter: TimeInterval = 2 * 3600     // two missed hourly updates
    private let maxOpenPRs = 5                          // more turns the headline red
    // Text below the subtitle is twice the size of the other pages' detail text.
    private let mergeRowHeight: CGFloat = 92

    private let service = GitHubService()
    private var snapshot: GitHubSnapshot?
    private var lastError: Error?
    private var lastSuccess: Date?

    private let repoRows = UIStackView()
    private let noOpenLabel = SpacedLabel(font: font(32), alpha: 0.6)
    private lazy var mergeHeading = sectionHeading("")
    private let mergeArea = UIView()
    private let mergeRows = UIStackView()
    private let dayFormatter = makeDateFormatter("MMM d")

    override func viewDidLoad() {
        super.viewDidLoad()
        let openHeading = sectionHeading("Open pull requests by repository")
        repoRows.axis = .vertical
        repoRows.spacing = 10
        for _ in 0..<5 { repoRows.addArrangedSubview(KeyValueRow(size: 32)) }
        noOpenLabel.textAlignment = .left
        noOpenLabel.set("No open pull requests")
        repoRows.insertArrangedSubview(noOpenLabel, at: 0)
        mergeHeading.set("Recent merges")

        mergeRows.axis = .vertical
        mergeRows.translatesAutoresizingMaskIntoConstraints = false
        mergeArea.clipsToBounds = true
        mergeArea.addSubview(mergeRows)

        let (rule, titleBar) = addTitleBar("GitHub · \(service.owner)")
        let header = addHeader("GitHub")

        let views: [UIView] = [openHeading, repoRows, mergeHeading, mergeArea]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let guide = view.safeAreaLayoutGuide
        let side: CGFloat = 24
        NSLayoutConstraint.activate([
            openHeading.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 32),
            openHeading.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: side),
            repoRows.topAnchor.constraint(equalTo: openHeading.bottomAnchor, constant: 14),
            repoRows.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: side),
            repoRows.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -side),

            mergeHeading.topAnchor.constraint(equalTo: repoRows.bottomAnchor, constant: 32),
            mergeHeading.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: side),
            mergeHeading.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -side),
            mergeArea.topAnchor.constraint(equalTo: mergeHeading.bottomAnchor, constant: 14),
            mergeArea.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: side),
            mergeArea.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -side),
            mergeArea.bottomAnchor.constraint(equalTo: rule.topAnchor, constant: -12),
            mergeRows.topAnchor.constraint(equalTo: mergeArea.topAnchor),
            mergeRows.leadingAnchor.constraint(equalTo: mergeArea.leadingAnchor),
            mergeRows.trailingAnchor.constraint(equalTo: mergeArea.trailingAnchor),

            titleBar.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -10),
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
                // IPADDASH_GITHUB_OPEN=<n> pretends n pull requests are open.
                if let n = ProcessInfo.processInfo.environment["IPADDASH_GITHUB_OPEN"].flatMap(Int.init) {
                    snapshot.openCount = n
                }
                #endif
                self.snapshot = snapshot
                self.lastError = nil
                self.lastSuccess = Date()
            case .failure(let error):
                self.lastError = error
            }
            completion()
        }
    }

    override func render() {
        let now = Date()
        if let s = snapshot {
            heroLabel.set(s.openCount == 1 ? "1 open pull request" : "\(s.openCount) open pull requests")
            summaryLabel.set("\(groupedNumber(s.merged24h)) merged in the last 24 h · \(groupedNumber(s.merged30d)) in 30 days")
            let recent: String
            switch s.merged24h {
            case 0: recent = "none"
            case 1: recent = "one"
            default: recent = groupedNumber(s.merged24h)
            }
            mergeHeading.set("Recent merges (\(recent) in the last 24 hours)")
            let top = Array(s.openByRepo.prefix(5))
            noOpenLabel.isHidden = !top.isEmpty
            // Unused slots collapse, so the merge list below gets the space.
            repoRows.showRows(top) { (row: KeyValueRow, entry) in
                let count = entry.count == 1 ? "1 PR" : "\(entry.count) PRs"
                // The age of the oldest open PR.
                let age = entry.oldest.map { " · " + durationText(now.timeIntervalSince($0)) } ?? ""
                row.set(entry.repo, count + age)
            }
            mergeRows.showRows(s.recentMerges) { (row: MergeRowView, pr) in
                let when = Calendar.current.isDateInToday(pr.mergedAt)
                    ? timeOfDayFormatter.string(from: pr.mergedAt) : self.dayFormatter.string(from: pr.mergedAt)
                row.configure(when: when, repo: "\(pr.repo) #\(pr.number) → \(pr.base)", title: pr.title)
            }
        } else {
            heroLabel.set(lastError?.localizedDescription ?? "loading…")
            summaryLabel.set("")
            noOpenLabel.isHidden = true
            repoRows.arrangedSubviews.forEach { $0.isHidden = true }
            mergeRows.arrangedSubviews.forEach { $0.isHidden = true }
        }
        let tooManyOpen = (snapshot?.openCount ?? 0) > maxOpenPRs
        heroLabel.alert = tooManyOpen || (snapshot == nil && lastError != nil)

        // Age of the data in minutes, counted from the last successful fetch.
        let age = lastSuccess.map { now.timeIntervalSince($0) }
        showStatus(error: lastError, hasData: snapshot != nil,
                   updated: age.map { "updated \(Int($0 / 60)) min ago" } ?? "")
        let stale = (age ?? 0) > staleAfter
        instanceLabel.alert = lastError != nil || stale
        var alerts: [PageAlert] = []
        if let error = lastError { alerts.append(PageAlert("GitHub", error: error)) }
        if stale, let age = age { alerts.append(PageAlert("GitHub data", "\(durationText(age)) old")) }
        if tooManyOpen, let s = snapshot { alerts.append(PageAlert("Open pull requests", "\(s.openCount)")) }
        self.alerts = alerts
    }

}

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
