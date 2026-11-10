import UIKit

/// Load and health of the k3s cluster "skylar-technology", from Grafana Cloud.
/// A split page: LOAD | SERVICES panels on top, 24 h graphs and operations rows below.
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

        let opsHeading = sectionHeading("Operations", size: 14)
        let bottom = UIStackView(arrangedSubviews: [cpuGraph, memGraph, opsHeading, backupRow, certRow, cronRow])
        bottom.axis = .vertical
        bottom.spacing = 10
        bottom.setCustomSpacing(20, after: cpuGraph)
        bottom.setCustomSpacing(24, after: memGraph)

        let lower = addSplitPage(left: loadPanel, right: servicesPanel, bar: "Cluster · skylar-technology")
        bottom.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottom)
        let graphHeight: CGFloat = 110
        NSLayoutConstraint.activate([
            bottom.topAnchor.constraint(equalTo: lower.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: lower.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: lower.trailingAnchor),
            bottom.bottomAnchor.constraint(lessThanOrEqualTo: lower.bottomAnchor),
            cpuGraph.heightAnchor.constraint(equalToConstant: graphHeight + 26),
            memGraph.heightAnchor.constraint(equalToConstant: graphHeight + 26),
        ])

        startFetching()
    }

    override func load(completion: @escaping () -> Void) {
        service.fetchSnapshot { result in
            result.store(in: &self.snapshot, error: &self.lastError)
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
        alerts = (lastError.map { [PageAlert("Cluster", error: $0)] } ?? [])
            + (snapshot?.attention ?? [])
    }
}
