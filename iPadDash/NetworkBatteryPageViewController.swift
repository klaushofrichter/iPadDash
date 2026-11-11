import Darwin
import Network
import SystemConfiguration.CaptiveNetwork
import UIKit

/// The battery level over the last day, sampled every few minutes and kept across
/// launches.
final class BatteryHistory: NSObject {
    static let shared = BatteryHistory()
    static let span: TimeInterval = 24 * 3600
    private let interval: TimeInterval = 5 * 60
    private let key = "batteryHistory"
    private var timer: Timer?
    private var lastSaved: Date?
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
        for name in [UIApplication.willResignActiveNotification, UIApplication.willTerminateNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(save), name: name, object: nil)
        }
    }

    private func record() {
        guard let level = ChargeControl.shared.batteryLevel else { return }
        let now = Date()
        samples.append((now, Double(level) * 100))
        // Oldest first, so only the front ages out.
        if let keep = samples.firstIndex(where: { now.timeIntervalSince($0.0) <= BatteryHistory.span }), keep > 0 {
            samples.removeFirst(keep)
        }
        // Written hourly (and when the app leaves the foreground), not every sample.
        if lastSaved.map({ now.timeIntervalSince($0) >= 3600 }) ?? true { save() }
    }

    @objc private func save() {
        lastSaved = Date()
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
    private let versionRow = KeyValueRow(size: 28)

    private var ssid: String?
    private var address: String?

    override func viewDidLoad() {
        super.viewDidLoad()
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
            sectionHeading("Battery", size: 22), indicator, plugRow, graphCaption, graph,
            sectionHeading("Network", size: 22), statusRow, connectionRow, wifiRow, addressRow, responseRow,
            sectionHeading("App", size: 22), versionRow,
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(28, after: plugRow)
        stack.setCustomSpacing(8, after: graphCaption)
        stack.setCustomSpacing(40, after: graph)

        let content = addFullPage(title: "Network & Battery")
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            graph.heightAnchor.constraint(equalToConstant: 200),
            batteryIcon.widthAnchor.constraint(equalToConstant: 92),
            batteryIcon.heightAnchor.constraint(equalToConstant: 42),
        ])

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(render), name: ChargeControl.didChange, object: nil)
        center.addObserver(self, selector: #selector(render), name: VersionCheck.didChange, object: nil)
        center.addObserver(self, selector: #selector(connectivityChanged), name: Connectivity.didChange, object: nil)
        startFetching()
    }

    @objc private func connectivityChanged() {
        readInterface()
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

    /// The iPad's own IPv4 address, Wi-Fi first.
    static func ipv4Address() -> String? {
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
        let network = Connectivity.shared
        let networkRed = network.outage != nil
        let version = VersionCheck.shared
        let alerts = [network.outageAlert, version.alert].compactMap { $0 } + charge.alerts

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
        if let battery = charge.batteryText { summary.append(battery) }
        summary.append(ssid.map { "Wi-Fi \($0)" } ?? connectionText)
        summaryLabel.set(summary.joined(separator: " · "))

        // Battery.
        levelLabel.set(charge.batteryPercent.map { "\($0)%" } ?? "–")
        levelLabel.alert = charge.isLow
        stateLabel.set(batteryStateText)
        stateLabel.alert = charge.notCharging
        batteryIcon.level = charge.batteryLevel.map(CGFloat.init)
        batteryIcon.charging = charge.isPowered
        batteryIcon.fillColor = charge.isLow ? alertInk : nil
        plugRow.set("Charging plug", charge.plugStatusText(), alert: charge.plugUnreachableFor != nil)
        let levels = BatteryHistory.shared.samples.filter { now.timeIntervalSince($0.0) <= BatteryHistory.span }.map { $0.1 }
        if let min = levels.min(), let max = levels.max() {
            graphCaption.set("Last 24 hours", "low \(Int(min.rounded()))% · high \(Int(max.rounded()))%")
        } else {
            graphCaption.set("Last 24 hours", "no data yet")
        }
        graph.points = BatteryHistory.shared.samples

        // Network.
        if let offline = network.offlineDuration {
            statusRow.set("Internet", "no response for \(durationText(offline))", alert: networkRed)
        } else {
            statusRow.set("Internet", "online")
        }
        connectionRow.set("Connection", connectionText, alert: network.path?.status == .unsatisfied && networkRed)
        wifiRow.set("Wi-Fi network", ssid ?? (network.path?.usesInterfaceType(.wifi) == true ? "name not available" : "none"))
        addressRow.set("IP address", address ?? "none")
        responseRow.set("Last server response",
                        network.lastResponse.map { timeOfDayFormatter.string(from: $0) } ?? "none yet")

        instanceLabel.set(UIDevice.current.name)
        if let newer = version.newerRelease {
            versionRow.set("Version \(version.installed)", "\(newer) available", alert: true)
        } else {
            versionRow.set("Version \(version.installed)", version.latest == nil ? "not checked yet"
                : version.latest == version.installed ? "latest release" : "not a release")
        }
        self.alerts = alerts
    }

    private var connectionText: String {
        guard let path = Connectivity.shared.path else { return "checking…" }
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

}

/// A battery outline filled to the level, with a lightning bolt while power is
/// connected. Drawn, since SF Symbols need iOS 13.
final class BatteryIconView: UIView {
    var level: CGFloat? { didSet { if level != oldValue { setNeedsDisplay() } } }
    var charging = false { didSet { if charging != oldValue { setNeedsDisplay() } } }
    /// The level's fill; nil is the ink.
    var fillColor: UIColor? { didSet { if fillColor != oldValue { setNeedsDisplay() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        // Proportions of the 92 × 42 icon on the Network & Battery page.
        let size = bounds.height
        let nubWidth = size / 7, line = max(1.5, size / 14), gap = size / 21
        let body = CGRect(x: line / 2, y: line / 2, width: bounds.width - nubWidth - line - gap,
                          height: bounds.height - line)
        let outline = UIBezierPath(roundedRect: body, cornerRadius: size / 5)
        ink.withAlphaComponent(0.6).setStroke()
        outline.lineWidth = line
        outline.stroke()
        let nub = CGRect(x: body.maxX + gap, y: body.midY - body.height * 0.18, width: nubWidth, height: body.height * 0.36)
        ink.withAlphaComponent(0.6).setFill()
        UIBezierPath(roundedRect: nub, byRoundingCorners: [.topRight, .bottomRight],
                     cornerRadii: CGSize(width: size / 14, height: size / 14)).fill()

        let inner = body.insetBy(dx: line + gap, dy: line + gap)
        if let level = level {
            let fill = CGRect(x: inner.minX, y: inner.minY, width: inner.width * min(max(level, 0), 1), height: inner.height)
            (fillColor ?? ink.withAlphaComponent(0.85)).setFill()
            UIBezierPath(roundedRect: fill, cornerRadius: size / 10).fill()
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
        bolt.lineWidth = line
        bolt.lineJoinStyle = .round
        paper.setStroke()
        bolt.stroke()
        (Theme.isDark ? UIColor(red: 0.98, green: 0.82, blue: 0.35, alpha: 1)
                      : UIColor(red: 0.85, green: 0.6, blue: 0.05, alpha: 1)).setFill()
        bolt.fill()
    }
}
