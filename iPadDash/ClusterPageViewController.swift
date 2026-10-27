import UIKit

/// Page 2: load and health of the k3s cluster "skylar-technology", from Grafana Cloud.
/// Top half: LOAD | SERVICES panels. Bottom half: 24 h graphs and operations rows.
final class ClusterPageViewController: UIViewController, DashboardPage {
    private let service = ClusterService()
    private var snapshot: ClusterSnapshot?
    private var lastError: Error?
    private var lastFetch: Date?
    private var fetching = false
    private var timer: Timer?

    private let loadPanel = LoadPanelView()
    private let servicesPanel = ServicesPanelView()
    private let cpuGraph = GraphBlockView(name: "CPU, 24 h")
    private let memGraph = GraphBlockView(name: "Memory, 24 h")
    private let backupRow = KeyValueRow()
    private let certRow = KeyValueRow()
    private let cronRow = KeyValueRow()
    private let instanceLabel = SpacedLabel(font: font(16))
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "h:mm a"
        return f
    }()

    override func loadView() {
        view = PaperView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let divider = InkView()
        let columns = UIStackView(arrangedSubviews: [loadPanel, divider, servicesPanel])
        columns.alignment = .fill
        divider.widthAnchor.constraint(equalToConstant: 2).isActive = true
        loadPanel.widthAnchor.constraint(equalTo: servicesPanel.widthAnchor).isActive = true

        let opsHeading = SpacedLabel(font: font(14, .bold), kern: 1, uppercase: true, alpha: 0.6)
        opsHeading.textAlignment = .left
        opsHeading.set("Operations")
        let bottom = UIStackView(arrangedSubviews: [cpuGraph, memGraph, opsHeading, backupRow, certRow, cronRow])
        bottom.axis = .vertical
        bottom.spacing = 10
        bottom.setCustomSpacing(20, after: cpuGraph)
        bottom.setCustomSpacing(24, after: memGraph)

        // Title bar like page 1: name on the left, last update on the right.
        let rule = InkView()
        let titleLabel = SpacedLabel(font: font(16, .bold))
        titleLabel.textAlignment = .left
        titleLabel.set("Cluster · skylar-technology")
        instanceLabel.textAlignment = .right
        let titleBar = UIStackView(arrangedSubviews: [titleLabel, instanceLabel])

        for v in [columns, rule, titleBar, bottom] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let guide = view.safeAreaLayoutGuide
        let graphHeight: CGFloat = 110
        NSLayoutConstraint.activate([
            columns.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            columns.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
            columns.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8),
            rule.topAnchor.constraint(equalTo: columns.bottomAnchor, constant: 8),
            rule.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            rule.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            rule.heightAnchor.constraint(equalToConstant: 2),
            titleBar.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 8),
            titleBar.leadingAnchor.constraint(equalTo: rule.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: rule.trailingAnchor),
            // The panels end at the middle of the screen, as on page 1.
            titleBar.bottomAnchor.constraint(equalTo: view.centerYAnchor, constant: -8),
            bottom.topAnchor.constraint(equalTo: view.centerYAnchor, constant: 20),
            bottom.leadingAnchor.constraint(equalTo: rule.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: rule.trailingAnchor),
            bottom.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor, constant: -8),
            cpuGraph.heightAnchor.constraint(equalToConstant: graphHeight + 26),
            memGraph.heightAnchor.constraint(equalToConstant: graphHeight + 26),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: Settings.didChange, object: nil)
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if lastFetch.map({ Date().timeIntervalSince($0) >= Settings.refreshInterval }) ?? true {
            fetch()
        }
        startTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
    }

    func reloadNow() {
        fetch()
        startTimer()
    }

    @objc private func settingsChanged() {
        if view.window != nil { startTimer() }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Settings.refreshInterval, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    private func fetch() {
        guard !fetching else { return }
        fetching = true
        render()
        service.fetchSnapshot { result in
            self.fetching = false
            self.lastFetch = Date()
            switch result {
            case .success(let snapshot): self.snapshot = snapshot; self.lastError = nil
            case .failure(let error): self.lastError = error
            }
            self.render()
        }
    }

    private func render() {
        let now = Date()
        if let s = snapshot {
            loadPanel.configure(with: s, now: now)
            servicesPanel.configure(with: s)
            cpuGraph.configure(history: s.cpuHistory, current: s.cpuPct)
            memGraph.configure(history: s.memHistory, current: s.memPct)

            if let age = s.backupAge {
                backupRow.set("Backup (Velero)", "\(ageText(age)) ago", alert: age > ClusterLimits.backupAge)
            } else {
                backupRow.set("Backup (Velero)", "n/a", alert: true)
            }
            if let days = s.certMinDays {
                let soonest = s.certMinName.map { name -> String in
                    " · " + (name.hasSuffix("-tls") ? String(name.dropLast(4)) : name)
                } ?? ""
                certRow.set("Certificates (\(s.certCount))", "next \(Int(days)) d\(soonest)",
                            alert: days < ClusterLimits.certDays)
            } else {
                certRow.set("Certificates", "n/a")
            }
            let lateJobs = s.cronJobs.filter { $0.age > ClusterLimits.cronJobAge }
            let jobs = s.cronJobs.map { "\($0.name) \(ageText($0.age))" }.joined(separator: " · ")
            cronRow.set("CronJobs", jobs.isEmpty ? "n/a" : jobs, alert: !lateJobs.isEmpty)
        } else {
            let message = lastError.map(errorText) ?? (fetching ? "loading…" : "")
            loadPanel.showError(message)
            servicesPanel.showError(message)
        }

        var instance = lastFetch.map { "updated \(timeFormatter.string(from: $0))" } ?? ""
        if fetching {
            instance = "refreshing…"
        } else if let error = lastError, snapshot != nil {
            instance = "fetch failed: \(errorText(error)) · " + instance
        }
        instanceLabel.set(instance)
        instanceLabel.alert = lastError != nil
    }

    private func errorText(_ error: Error) -> String {
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
