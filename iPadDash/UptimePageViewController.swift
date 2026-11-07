import UIKit

/// Page 3: UptimeRobot monitors, modeled on the public status page. A monitor
/// that is down turns its row red; the headline turns red if any is down.
final class UptimePageViewController: DashboardPageViewController {
    private let service = UptimeService()
    private var monitors: [UptimeMonitor]?
    private var lastError: Error?

    private let heroLabel = SpacedLabel(font: font(36, .heavy))
    private let summaryLabel = SpacedLabel(font: font(16), alpha: 0.6)
    private let list = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        let title = SpacedLabel(font: font(26, .bold), kern: 2)
        title.set("UPTIME")

        list.axis = .vertical
        list.distribution = .fillEqually
        list.spacing = 8

        let (rule, titleBar) = addTitleBar("Uptime · UptimeRobot")

        for v in [title, heroLabel, summaryLabel, list] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: guide.topAnchor, constant: 26),
            title.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            heroLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            heroLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            heroLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            summaryLabel.topAnchor.constraint(equalTo: heroLabel.bottomAnchor, constant: 6),
            summaryLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            list.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 22),
            list.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            list.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            rule.topAnchor.constraint(equalTo: list.bottomAnchor, constant: 16),
            titleBar.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -10),
        ])

        startFetching()
    }

    override func load(completion: @escaping () -> Void) {
        service.fetchMonitors { result in
            switch result {
            case .success(var monitors):
                #if DEBUG
                // IPADDASH_UPTIME_DOWN=<index> pretends that monitor went down 12 minutes ago.
                if let i = ProcessInfo.processInfo.environment["IPADDASH_UPTIME_DOWN"].flatMap(Int.init),
                   monitors.indices.contains(i) {
                    let m = monitors[i]
                    monitors[i] = UptimeMonitor(name: m.name, status: .down, uptime30: m.uptime30,
                                                daily: m.daily.dropLast() + [98.5],
                                                downSince: Date().addingTimeInterval(-12 * 60))
                }
                #endif
                self.monitors = monitors
                self.lastError = nil
            case .failure(let error): self.lastError = error
            }
            completion()
        }
    }

    override func render() {
        let now = Date()
        if let monitors = monitors {
            let down = monitors.filter { $0.status == .down }
            heroLabel.set(down.isEmpty ? "All systems operational"
                                       : "\(down.count) \(down.count == 1 ? "service" : "services") down")
            heroLabel.alert = !down.isEmpty
            let ratios = monitors.compactMap { $0.uptime30 }
            let average = ratios.isEmpty ? "" : String(format: " · %.3f%% average uptime, 30 days",
                                                         ratios.reduce(0, +) / Double(ratios.count))
            summaryLabel.set("\(monitors.count) monitors\(average)")

            while list.arrangedSubviews.count < monitors.count { list.addArrangedSubview(MonitorRowView()) }
            for (index, view) in list.arrangedSubviews.enumerated() {
                guard let row = view as? MonitorRowView else { continue }
                row.isHidden = index >= monitors.count
                if index < monitors.count { row.configure(with: monitors[index], now: now) }
            }
        } else {
            heroLabel.set(lastError?.localizedDescription ?? "loading…")
            heroLabel.alert = lastError != nil
            summaryLabel.set("")
        }

        showStatus(error: lastError, hasData: monitors != nil)
        instanceLabel.alert = lastError != nil
        var alerts: [PageAlert] = []
        if let error = lastError { alerts.append(PageAlert("Uptime", error: error)) }
        for m in monitors ?? [] where m.status == .down {
            alerts.append(PageAlert("Down: \(m.name)", m.downSince.map { ageText(now.timeIntervalSince($0)) } ?? ""))
        }
        self.alerts = alerts
    }
}

/// One monitor: name and "99.988% · UP" on top, 30 daily uptime bars below.
final class MonitorRowView: UIView {
    private let nameLabel = SpacedLabel(font: font(17, .semibold))
    private let uptimeLabel = SpacedLabel(font: font(15), alpha: 0.7)
    private let statusLabel = SpacedLabel(font: font(15, .bold), kern: 1, uppercase: true)
    private let bars = DayBarsView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        nameLabel.textAlignment = .left
        uptimeLabel.textAlignment = .right
        statusLabel.textAlignment = .right
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for label in [uptimeLabel, statusLabel] {
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let head = UIStackView(arrangedSubviews: [nameLabel, uptimeLabel, statusLabel])
        head.spacing = 14
        let stack = UIStackView(arrangedSubviews: [head, bars])
        stack.axis = .vertical
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with monitor: UptimeMonitor, now: Date) {
        let down = monitor.status == .down
        nameLabel.set(monitor.name)
        uptimeLabel.set(monitor.uptime30.map { String(format: "%.3f%%", $0) } ?? "")
        switch monitor.status {
        case .up: statusLabel.set("up")
        case .down: statusLabel.set(monitor.downSince.map { "down \(ageText(now.timeIntervalSince($0)))" } ?? "down")
        case .paused: statusLabel.set("paused")
        case .pending: statusLabel.set("pending")
        }
        for label in [nameLabel, uptimeLabel, statusLabel] { label.alert = down }
        bars.days = monitor.daily
        bars.alert = down
    }
}

/// One bar per day, oldest left: full ink for 100 %, faded for a short dip,
/// red below 99 %, a faint stub when there is no data.
final class DayBarsView: UIView {
    var days: [Double?] = [] { didSet { setNeedsDisplay() } }
    var alert = false { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard !days.isEmpty else { return }
        let base = alert ? alertInk : ink
        let gap: CGFloat = 3
        let width = (bounds.width - gap * CGFloat(days.count - 1)) / CGFloat(days.count)
        for (i, day) in days.enumerated() {
            let x = CGFloat(i) * (width + gap)
            let color: UIColor
            switch day {
            case .none: color = base.withAlphaComponent(0.12)
            case .some(let pct) where pct >= 100: color = base.withAlphaComponent(0.85)
            case .some(let pct) where pct >= 99: color = base.withAlphaComponent(0.4)
            default: color = alertInk
            }
            color.setFill()
            UIBezierPath(roundedRect: CGRect(x: x, y: 0, width: width, height: bounds.height), cornerRadius: 2).fill()
        }
    }
}
