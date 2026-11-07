import Darwin
import Network
import SystemConfiguration.CaptiveNetwork
import UIKit

/// The battery level over the last day, sampled every few minutes and kept across
/// launches.
final class BatteryHistory {
    static let shared = BatteryHistory()
    static let span: TimeInterval = 24 * 3600
    private let interval: TimeInterval = 5 * 60
    private let key = "batteryHistory"
    private var timer: Timer?
    /// Oldest first; level in percent.
    private(set) var samples: [(Date, Double)] = []

    func start() {
        let stored = UserDefaults.standard.array(forKey: key) as? [[Double]] ?? []
        samples = stored.compactMap { $0.count == 2 ? (Date(timeIntervalSince1970: $0[0]), $0[1]) : nil }
        #if DEBUG
        // Test aid: IPADDASH_BATTERY_HISTORY=1 draws a made-up day of charging and discharging.
        if ProcessInfo.processInfo.environment["IPADDASH_BATTERY_HISTORY"] != nil {
            let now = Date()
            samples = stride(from: BatteryHistory.span, through: 0, by: -interval).map { ago -> (Date, Double) in
                let phase = (ago / 3600).truncatingRemainder(dividingBy: 10) / 10   // a 10-hour cycle
                let level = phase < 0.3 ? 15 + phase / 0.3 * 65 : 80 - (phase - 0.3) / 0.7 * 65
                return (now.addingTimeInterval(-ago), level)
            }
        }
        #endif
        record()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.record() }
    }

    private func record() {
        guard let level = ChargeControl.shared.batteryLevel else { return }
        let now = Date()
        samples.append((now, Double(level) * 100))
        samples.removeAll { now.timeIntervalSince($0.0) > BatteryHistory.span }
        UserDefaults.standard.set(samples.map { [$0.0.timeIntervalSince1970, $0.1] }, forKey: key)
    }
}

/// Battery level, its last day and the charging plug, and how the iPad is connected.
/// Only in the rotation (and named on the summary page) while something here is red:
/// battery low or a plug problem, or a network outage (`Connectivity.outage`).
final class NetworkBatteryPageViewController: DashboardPageViewController {
    override var onlyWhenRed: Bool { return true }
    override var fixedFetchInterval: TimeInterval? { return 60 }
    override var redrawInterval: TimeInterval? { return 30 }

    private let heroLabel = SpacedLabel(font: font(36, .heavy))
    private let summaryLabel = SpacedLabel(font: font(16), alpha: 0.6)
    private let batteryIcon = BatteryIconView()
    private let levelLabel = SpacedLabel(font: font(44, .semibold))
    private let stateLabel = SpacedLabel(font: font(28), alpha: 0.7)
    private let plugRow = KeyValueRow(size: 28)
    private let graphCaption = KeyValueRow(size: 20)
    private let graph = LineGraphView()
    private let statusRow = KeyValueRow(size: 28)
    private let connectionRow = KeyValueRow(size: 28)
    private let wifiRow = KeyValueRow(size: 28)
    private let addressRow = KeyValueRow(size: 28)
    private let responseRow = KeyValueRow(size: 28)

    private let monitor = NWPathMonitor()
    private var path: NWPath?
    private var ssid: String?
    private var address: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        let title = SpacedLabel(font: font(26, .bold), kern: 2)
        title.set("NETWORK & BATTERY")
        graph.limit = Double(ChargeControl.lowBelow * 100)
        graph.showsScale = true
        graph.redBelowLimit = true
        levelLabel.textAlignment = .left
        stateLabel.textAlignment = .left
        let indicator = UIStackView(arrangedSubviews: [batteryIcon, levelLabel, stateLabel, UIView()])
        indicator.alignment = .center
        indicator.spacing = 18
        indicator.setCustomSpacing(12, after: levelLabel)

        let stack = UIStackView(arrangedSubviews: [
            heading("Battery"), indicator, plugRow, graphCaption, graph,
            heading("Network"), statusRow, connectionRow, wifiRow, addressRow, responseRow,
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(28, after: plugRow)
        stack.setCustomSpacing(8, after: graphCaption)
        stack.setCustomSpacing(40, after: graph)

        let (rule, titleBar) = addTitleBar("Network & Battery")
        for v in [title, heroLabel, summaryLabel, stack] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: guide.topAnchor, constant: 26),
            title.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            heroLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            heroLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            summaryLabel.topAnchor.constraint(equalTo: heroLabel.bottomAnchor, constant: 6),
            summaryLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 32),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: rule.topAnchor, constant: -16),
            graph.heightAnchor.constraint(equalToConstant: 200),
            batteryIcon.widthAnchor.constraint(equalToConstant: 92),
            batteryIcon.heightAnchor.constraint(equalToConstant: 42),
            titleBar.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -10),
        ])

        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.path = path
                self?.readInterface()
                self?.render()
            }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkBatteryPage"))
        let center = NotificationCenter.default
        for name in [ChargeControl.didChange, Connectivity.didChange] {
            center.addObserver(self, selector: #selector(changed), name: name, object: nil)
        }
        startFetching()
    }

    @objc private func changed() {
        render()
    }

    override func load(completion: @escaping () -> Void) {
        readInterface()
        completion()
    }

    /// The Wi-Fi network's name (needs the Access WiFi Information entitlement) and
    /// the iPad's IPv4 address.
    private func readInterface() {
        ssid = nil
        if let interfaces = CNCopySupportedInterfaces() as? [String] {
            for name in interfaces {
                if let info = CNCopyCurrentNetworkInfo(name as CFString) as? [String: Any],
                   let value = info[kCNNetworkInfoKeySSID as String] as? String {
                    ssid = value
                    break
                }
            }
        }
        address = NetworkBatteryPageViewController.ipv4Address()
    }

    private static func ipv4Address() -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }
        defer { freeifaddrs(first) }
        var fallback: String?
        var cursor = first
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.ifa_name)
            guard name != "lo0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if name == "en0" { return text }   // Wi-Fi
            if fallback == nil { fallback = text }
        }
        return fallback
    }

    override func render() {
        guard isViewLoaded else { return }
        let now = Date()
        let charge = ChargeControl.shared
        let chargeAlerts = charge.alerts
        var alerts = chargeAlerts
        var offlineText: String?
        if let offline = Connectivity.shared.offlineDuration { offlineText = durationText(offline) }
        if let outage = Connectivity.shared.outage { alerts.insert(PageAlert("No network", durationText(outage)), at: 0) }
        let networkRed = alerts.count > chargeAlerts.count

        // Headline and one-line summary.
        if alerts.isEmpty {
            heroLabel.set("All good")
        } else if alerts.count == 1 {
            heroLabel.set(alerts[0].what)
        } else {
            heroLabel.set("\(alerts.count) problems")
        }
        heroLabel.alert = !alerts.isEmpty
        var summary: [String] = []
        if let battery = charge.batteryText { summary.append("Battery \(battery)") }
        summary.append(ssid.map { "Wi-Fi \($0)" } ?? connectionText)
        summaryLabel.set(summary.joined(separator: " · "))

        // Battery.
        let low = chargeAlerts.contains { $0.what == "Battery low" }
        let notCharging = chargeAlerts.contains { $0.what == "Not charging" }
        levelLabel.set(charge.batteryLevel.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
        levelLabel.alert = low
        stateLabel.set(batteryStateText)
        stateLabel.alert = notCharging
        batteryIcon.level = charge.batteryLevel.map(CGFloat.init)
        batteryIcon.charging = charge.isPowered
        batteryIcon.alert = low
        plugRow.set("Charging plug", plugText, alert: chargeAlerts.contains { $0.what == "Charging plug" })
        let levels = BatteryHistory.shared.samples.filter { now.timeIntervalSince($0.0) <= BatteryHistory.span }.map { $0.1 }
        if let min = levels.min(), let max = levels.max() {
            graphCaption.set("Last 24 hours", "low \(Int(min.rounded()))% · high \(Int(max.rounded()))%")
        } else {
            graphCaption.set("Last 24 hours", "no data yet")
        }
        graph.points = BatteryHistory.shared.samples

        // Network.
        if let offline = offlineText {
            statusRow.set("Internet", "no response for \(offline)", alert: networkRed)
        } else {
            statusRow.set("Internet", "online")
        }
        connectionRow.set("Connection", connectionText, alert: path?.status == .unsatisfied && networkRed)
        wifiRow.set("Wi-Fi network", ssid ?? (path?.usesInterfaceType(.wifi) == true ? "name not available" : "none"))
        addressRow.set("IP address", address ?? "none")
        responseRow.set("Last server response",
                        Connectivity.shared.lastResponse.map { timeOfDayFormatter.string(from: $0) } ?? "none yet")

        instanceLabel.set(UIDevice.current.name)
        self.alerts = alerts
    }

    private var connectionText: String {
        guard let path = path else { return "checking…" }
        guard path.status == .satisfied else { return "no connection" }
        if path.usesInterfaceType(.wifi) { return "Wi-Fi" }
        if path.usesInterfaceType(.wiredEthernet) { return "wired" }
        if path.usesInterfaceType(.cellular) { return "cellular" }
        return "connected"
    }

    private var batteryStateText: String {
        switch UIDevice.current.batteryState {
        case .charging: return "charging"
        case .full: return "full · on power"
        case .unplugged: return "on battery"
        default: return ChargeControl.shared.isPowered ? "charging" : "unknown"
        }
    }

    private var plugText: String {
        let charge = ChargeControl.shared
        guard charge.isOn else { return "not set up" }
        var parts: [String] = []
        if let on = charge.plugOn { parts.append(on ? "on" : "off") }
        if charge.lastError != nil {
            parts.append("unreachable")
        } else if let contact = charge.lastContact {
            parts.append("checked \(timeOfDayFormatter.string(from: contact))")
        } else {
            parts.append("contacting…")
        }
        return parts.joined(separator: " · ")
    }

    private func heading(_ text: String) -> SpacedLabel {
        let label = SpacedLabel(font: font(22, .bold), kern: 1, uppercase: true, alpha: 0.6)
        label.textAlignment = .left
        label.set(text)
        return label
    }
}

/// A battery outline filled to the level, with a lightning bolt while power is
/// connected. Drawn, since SF Symbols need iOS 13.
final class BatteryIconView: UIView {
    var level: CGFloat? { didSet { setNeedsDisplay() } }
    var charging = false { didSet { setNeedsDisplay() } }
    var alert = false { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: Theme.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func redraw() { setNeedsDisplay() }

    override func draw(_ rect: CGRect) {
        let nubWidth: CGFloat = 6, line: CGFloat = 3
        let body = CGRect(x: line / 2, y: line / 2, width: bounds.width - nubWidth - line - 2,
                          height: bounds.height - line)
        let outline = UIBezierPath(roundedRect: body, cornerRadius: 8)
        ink.withAlphaComponent(0.6).setStroke()
        outline.lineWidth = line
        outline.stroke()
        let nub = CGRect(x: body.maxX + 2, y: body.midY - body.height * 0.18, width: nubWidth, height: body.height * 0.36)
        ink.withAlphaComponent(0.6).setFill()
        UIBezierPath(roundedRect: nub, byRoundingCorners: [.topRight, .bottomRight],
                     cornerRadii: CGSize(width: 3, height: 3)).fill()

        let inner = body.insetBy(dx: line + 2, dy: line + 2)
        if let level = level {
            let fill = CGRect(x: inner.minX, y: inner.minY, width: inner.width * min(max(level, 0), 1), height: inner.height)
            (alert ? alertInk : ink.withAlphaComponent(0.85)).setFill()
            UIBezierPath(roundedRect: fill, cornerRadius: 4).fill()
        }
        guard charging else { return }
        // A bolt in the middle, cut out of the fill by a background-colored outline.
        let w = inner.height * 0.62, h = inner.height * 1.15
        let o = CGPoint(x: inner.midX - w / 2, y: inner.midY - h / 2)
        let bolt = UIBezierPath()
        bolt.move(to: CGPoint(x: o.x + w * 0.62, y: o.y))
        bolt.addLine(to: CGPoint(x: o.x + w * 0.05, y: o.y + h * 0.58))
        bolt.addLine(to: CGPoint(x: o.x + w * 0.45, y: o.y + h * 0.58))
        bolt.addLine(to: CGPoint(x: o.x + w * 0.38, y: o.y + h))
        bolt.addLine(to: CGPoint(x: o.x + w * 0.95, y: o.y + h * 0.42))
        bolt.addLine(to: CGPoint(x: o.x + w * 0.55, y: o.y + h * 0.42))
        bolt.close()
        bolt.lineWidth = 3
        bolt.lineJoinStyle = .round
        paper.setStroke()
        bolt.stroke()
        (Theme.isDark ? UIColor(red: 0.98, green: 0.82, blue: 0.35, alpha: 1)
                      : UIColor(red: 0.85, green: 0.6, blue: 0.05, alpha: 1)).setFill()
        bolt.fill()
    }
}
