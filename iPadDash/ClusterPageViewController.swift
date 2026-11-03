import UIKit

/// Page 2: load and health of the k3s cluster "skylar-technology", from Grafana Cloud.
/// Top half: LOAD | SERVICES panels. Bottom half: 24 h graphs and operations rows.
final class ClusterPageViewController: DashboardPageViewController {
    private let service = ClusterService()
    private var snapshot: ClusterSnapshot?
    private var lastError: Error?

    private let loadPanel = LoadPanelView()
    private let servicesPanel = ServicesPanelView()
    private let cpuGraph = GraphBlockView(name: "CPU, 24 h")
    private let memGraph = GraphBlockView(name: "Memory, 24 h")
    private let backupRow = KeyValueRow()
    private let certRow = KeyValueRow()
    private let cronRow = KeyValueRow()

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
        let (rule, titleBar) = addTitleBar("Cluster · skylar-technology")

        for v in [columns, bottom] as [UIView] {
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
            // The panels end at the middle of the screen, as on page 1.
            titleBar.bottomAnchor.constraint(equalTo: view.centerYAnchor, constant: -8),
            bottom.topAnchor.constraint(equalTo: view.centerYAnchor, constant: 20),
            bottom.leadingAnchor.constraint(equalTo: rule.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: rule.trailingAnchor),
            bottom.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor, constant: -8),
            cpuGraph.heightAnchor.constraint(equalToConstant: graphHeight + 26),
            memGraph.heightAnchor.constraint(equalToConstant: graphHeight + 26),
        ])

        startFetching()
    }

    override func load(completion: @escaping () -> Void) {
        service.fetchSnapshot { result in
            switch result {
            case .success(let snapshot): self.snapshot = snapshot; self.lastError = nil
            case .failure(let error): self.lastError = error
            }
            completion()
        }
    }

    override func render() {
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
            let message = lastError?.localizedDescription ?? (fetching ? "loading…" : "")
            loadPanel.showError(message)
            servicesPanel.showError(message)
        }

        showStatus(error: lastError, hasData: snapshot != nil)
        instanceLabel.alert = lastError != nil
        hasAlert = snapshot?.needsAttention ?? false || lastError != nil
    }
}
