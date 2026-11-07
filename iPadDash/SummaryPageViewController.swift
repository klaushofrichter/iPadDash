import UIKit

/// The optional home page (Settings.summaryPage): everything the other pages draw
/// in red, at most five, in the style of the GitHub page; below it a large clock,
/// the date, and the temperature for the next nine hours where the iPad is.
final class SummaryPageViewController: DashboardPageViewController {
    override var fixedFetchInterval: TimeInterval? { return 30 * 60 }   // weather
    override var redrawInterval: TimeInterval? { return 1 }             // clock
    private let maxRows = 5

    /// The pages whose red items are listed; set by the root.
    var sources: [DashboardPageViewController] = [] { didSet { buildSourceNames(); if isViewLoaded { render() } } }
    /// Shows a page; set by the root. Red rows and the page names lead to their page.
    var openPage: ((DashboardPageViewController) -> Void)?
    private var rowTargets: [DashboardPageViewController?] = []

    private let service = WeatherService()
    private var forecast: WeatherForecast?
    private var lastError: Error?

    private let heroLabel = SpacedLabel(font: font(36, .heavy))
    /// "Steps & Claude · Cluster · …": each name leads to its page, and turns red
    /// while that page has red items.
    private let sourceNames = UIStackView()
    private var sourceLabels: [(label: SpacedLabel, page: DashboardPageViewController, dot: UIView?)] = []
    private let moreLabel = SpacedLabel(font: font(18), alpha: 0.6)
    private let alertRows = UIStackView()
    /// "Red on the dashboard" over the red items; it and the rows are hidden when there are none.
    private lazy var alertHeading = sectionHeading("Red on the dashboard")
    /// The clock and weather start below the red items, or right below the names when there are none.
    private lazy var lowerBelowRows = lowerArea.topAnchor.constraint(equalTo: alertRows.bottomAnchor, constant: 24)
    private lazy var lowerBelowNames = lowerArea.topAnchor.constraint(equalTo: sourceNames.bottomAnchor, constant: 24)
    /// When the forecast was last fetched successfully.
    private var weatherUpdated: Date?
    private let timeLabel = SpacedLabel(font: UIFont.monospacedDigitSystemFont(ofSize: 150 * scale, weight: .light))
    private let dateLabel = SpacedLabel(font: font(34), alpha: 0.85)
    private lazy var weatherHeading = sectionHeading("Weather")
    private let weatherNote = SpacedLabel(font: font(24), alpha: 0.6)
    /// Hourly columns shown; the forecast fetches a few more so a past hour dropping
    /// off between fetches doesn't leave a column empty.
    static let hours = 9
    private let hourColumns = UIStackView()
    private let graph = TemperatureGraphView()
    private let weather = UIStackView()
    private let lower = UIStackView()
    private let lowerArea = UIView()
    private var fitting = false
    private let timeFormatter = SummaryPageViewController.formatter("h:mm")
    private let dateFormatter = SummaryPageViewController.formatter("EEEE, MMMM d")
    private let hourFormatter = SummaryPageViewController.formatter("h a")

    override func viewDidLoad() {
        super.viewDidLoad()
        let title = SpacedLabel(font: font(26, .bold), kern: 2)
        title.set("SUMMARY")

        alertRows.axis = .vertical
        alertRows.spacing = 10
        for _ in 0..<maxRows {
            let row = KeyValueRow(size: 32)
            row.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(rowTapped(_:))))
            alertRows.addArrangedSubview(row)
        }
        moreLabel.textAlignment = .left
        alertRows.addArrangedSubview(moreLabel)
        sourceNames.alignment = .center
        buildSourceNames()

        // The rest of the page: clock, date and weather, centered in the space left.
        hourColumns.distribution = .fillEqually
        for _ in 0..<SummaryPageViewController.hours { hourColumns.addArrangedSubview(HourColumnView()) }
        weatherNote.textAlignment = .center
        weatherHeading.textAlignment = .center
        for v in [weatherHeading, hourColumns, weatherNote] { weather.addArrangedSubview(v) }
        weather.axis = .vertical
        weather.spacing = 14
        // Top to bottom = most to least important; fitLowerSections() drops from the bottom.
        for v in [timeLabel, dateLabel, weather, graph] { lower.addArrangedSubview(v) }
        lower.axis = .vertical
        lower.alignment = .fill
        lower.setCustomSpacing(12, after: timeLabel)
        lower.setCustomSpacing(48, after: dateLabel)
        lower.setCustomSpacing(20, after: weather)
        lowerArea.clipsToBounds = true
        lower.translatesAutoresizingMaskIntoConstraints = false
        lowerArea.addSubview(lower)

        let (rule, titleBar) = addTitleBar("Summary")

        for v in [title, heroLabel, sourceNames, alertHeading, alertRows, lowerArea] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let guide = view.safeAreaLayoutGuide
        let side: CGFloat = 24
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: guide.topAnchor, constant: 26),
            title.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            heroLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            heroLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            sourceNames.topAnchor.constraint(equalTo: heroLabel.bottomAnchor, constant: -2),
            sourceNames.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            alertHeading.topAnchor.constraint(equalTo: sourceNames.bottomAnchor, constant: 24),
            alertHeading.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: side),
            alertRows.topAnchor.constraint(equalTo: alertHeading.bottomAnchor, constant: 14),
            alertRows.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: side),
            alertRows.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -side),

            lowerBelowRows,
            lowerArea.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: side),
            lowerArea.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -side),
            lowerArea.bottomAnchor.constraint(equalTo: rule.topAnchor, constant: -12),
            lower.leadingAnchor.constraint(equalTo: lowerArea.leadingAnchor),
            lower.trailingAnchor.constraint(equalTo: lowerArea.trailingAnchor),
            lower.centerYAnchor.constraint(equalTo: lowerArea.centerYAnchor),

            titleBar.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -10),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(alertsChanged),
                                               name: pageAlertDidChange, object: nil)
        startFetching()
    }

    override func load(completion: @escaping () -> Void) {
        service.fetchForecast { result in
            switch result {
            case .success(var forecast):
                #if DEBUG
                // Test aid: IPADDASH_FAKE_TEMPS=-4,2,9,... replaces the hourly temperatures.
                if let temps = ProcessInfo.processInfo.environment["IPADDASH_FAKE_TEMPS"]?
                    .split(separator: ",").compactMap({ Double($0) }) {
                    forecast.hours = zip(forecast.hours, temps).map { HourlyTemperature(time: $0.time, celsius: $1) }
                }
                #endif
                self.forecast = forecast; self.lastError = nil
                self.weatherUpdated = Date()
            case .failure(let error): self.lastError = error
            }
            completion()
        }
    }

    @objc private func alertsChanged() {
        if isViewLoaded { render() }
    }

    override func render() {
        let now = Date()
        var items: [(alert: PageAlert, page: DashboardPageViewController?)] = []
        // During an outage, "No network" says it once instead of every page's failed fetch.
        let outage = Connectivity.shared.outage != nil
        for page in sources { items += page.alerts.filter { !(outage && $0.offline) }.map { ($0, page) } }
        #if DEBUG
        // Test aid: IPADDASH_FAKE_ALERTS=N adds N made-up red items (on the first page).
        if let n = ProcessInfo.processInfo.environment["IPADDASH_FAKE_ALERTS"].flatMap({ Int($0) }) {
            items += (0..<n).map { (PageAlert("Test item \($0 + 1)", "made up"), sources.first) }
        }
        #endif

        heroLabel.set(items.isEmpty ? "No Current Red Alert" : items.count == 1 ? "One Red Item" : "\(items.count) Red Items")
        heroLabel.alert = !items.isEmpty
        for (label, page, dot) in sourceLabels {
            let red = page.hasAlert   // like its page dot, even when its rows are left out
            // A page that joins the rotation only when red is named only then.
            label.superview?.isHidden = page.onlyWhenRed && !red
            dot?.isHidden = page.onlyWhenRed && !red
            label.alert = red
            label.alphaOfInk = red ? 1 : 0.6
            label.refresh()
        }
        alertHeading.isHidden = items.isEmpty
        alertRows.isHidden = items.isEmpty
        // Deactivate first, so the two are never on together.
        let (on, off) = items.isEmpty ? (lowerBelowNames, lowerBelowRows) : (lowerBelowRows, lowerBelowNames)
        off.isActive = false
        on.isActive = true
        let rows = alertRows.arrangedSubviews.compactMap { $0 as? KeyValueRow }
        rowTargets = rows.indices.map { $0 < items.count ? items[$0].page : nil }
        for (index, row) in rows.enumerated() {
            row.isHidden = index >= items.count
            row.gestureRecognizers?.forEach { $0.isEnabled = rowTargets[index] != nil }
            if index < items.count { row.set(items[index].alert.what, items[index].alert.detail, alert: true) }
        }
        moreLabel.set(items.count > maxRows ? "+ \(items.count - maxRows) more · tap a name above to see its page" : "")
        moreLabel.isHidden = items.count <= maxRows

        timeLabel.set(timeFormatter.string(from: now))
        dateLabel.set(dateFormatter.string(from: now))

        let place = forecast?.place.map { " · \($0)" } ?? ""
        weatherHeading.set("Weather\(place) · next \(SummaryPageViewController.hours) hours, °C")
        // Hours already past drop off between fetches.
        let upcoming = (forecast?.hours ?? []).filter { $0.time > now.addingTimeInterval(-3600) }
        for (index, view) in hourColumns.arrangedSubviews.enumerated() {
            guard let column = view as? HourColumnView else { continue }
            if index < upcoming.count {
                let hour = upcoming[index]
                column.configure(hour: hourFormatter.string(from: hour.time),
                                 temperature: "\(Int(hour.celsius.rounded()))°",
                                 color: TemperatureGraphView.color(for: hour.celsius))
            } else {
                column.configure(hour: "", temperature: "", color: nil)
            }
        }
        if upcoming.isEmpty {
            weatherNote.set(lastError.map { "weather: \($0.localizedDescription)" } ?? (fetching ? "loading…" : ""))
        } else {
            weatherNote.set("")
        }
        weatherNote.isHidden = !upcoming.isEmpty
        hourColumns.isHidden = upcoming.isEmpty
        graph.temperatures = upcoming.prefix(SummaryPageViewController.hours).map { $0.celsius }
        view.setNeedsLayout()
        instanceLabel.set(weatherAgeText(now: now))
    }

    /// How old the forecast is: current within one fetch interval (plus a minute's
    /// slack for the fetch itself), then minutes up to two hours, then hours up to four.
    private func weatherAgeText(now: Date) -> String {
        guard let updated = weatherUpdated else {
            return fetching ? "Loading weather data…" : "No weather data"
        }
        let minutes = Int(now.timeIntervalSince(updated) / 60)
        let currentFor = Int((fixedFetchInterval ?? 30 * 60) / 60) + 1
        if minutes < currentFor { return "Weather data is current" }
        if minutes < 120 { return "Weather data updated \(minutes) minutes ago" }
        if minutes < 4 * 60 { return "Weather data updated less than \(minutes / 60 + 1) hours ago" }
        return "Weather data outdated"
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        fitLowerSections()
    }

    /// Shows as many of clock, date, hourly numbers and graph as fit below the red
    /// items, dropping from the bottom (graph first, clock last).
    private func fitLowerSections() {
        let width = lowerArea.bounds.width, available = lowerArea.bounds.height
        guard !fitting, width > 0 else { return }
        fitting = true
        defer { fitting = false }
        let sections: [UIView] = [timeLabel, dateLabel, weather, graph]
        let wanted = [true, true, true, graph.temperatures.count >= 2]
        var used: CGFloat = 0
        var fits = true
        for (index, section) in sections.enumerated() {
            let gap = index == 0 ? 0 : lower.customSpacing(after: sections[index - 1])
            let height = section.systemLayoutSizeFitting(
                CGSize(width: width, height: 0),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
            fits = fits && wanted[index] && used + gap + height <= available
            if fits { used += gap + height }
            if section.isHidden == fits { section.isHidden = !fits }
        }
    }

    private func buildSourceNames() {
        sourceNames.arrangedSubviews.forEach { $0.removeFromSuperview() }
        sourceLabels = []
        for (index, page) in sources.enumerated() {
            var dot: SpacedLabel?
            if index > 0 {
                dot = SpacedLabel(font: font(16), alpha: 0.6)
                dot?.set("·")
                sourceNames.addArrangedSubview(dot!)
            }
            let label = SpacedLabel(font: font(16), alpha: 0.6)
            label.set(page.pageName)
            // A taller, wider target than the small text itself.
            let target = UIView()
            label.translatesAutoresizingMaskIntoConstraints = false
            target.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: target.topAnchor, constant: 10),
                label.bottomAnchor.constraint(equalTo: target.bottomAnchor, constant: -10),
                label.leadingAnchor.constraint(equalTo: target.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: target.trailingAnchor, constant: -6),
            ])
            target.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(nameTapped(_:))))
            sourceNames.addArrangedSubview(target)
            sourceLabels.append((label, page, dot))
        }
    }

    @objc private func rowTapped(_ recognizer: UITapGestureRecognizer) {
        let rows = alertRows.arrangedSubviews.compactMap { $0 as? KeyValueRow }
        guard let view = recognizer.view as? KeyValueRow, let index = rows.firstIndex(of: view),
              index < rowTargets.count, let page = rowTargets[index] else { return }
        openPage?(page)
    }

    @objc private func nameTapped(_ recognizer: UITapGestureRecognizer) {
        guard let entry = sourceLabels.first(where: { $0.label.superview === recognizer.view }) else { return }
        openPage?(entry.page)
    }

    private func sectionHeading(_ text: String) -> SpacedLabel {
        let label = SpacedLabel(font: font(28, .bold), kern: 1, uppercase: true, alpha: 0.6)
        label.textAlignment = .left
        label.set(text)
        return label
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = format
        return f
    }
}

/// One hour of the forecast: "2 PM" over "14°".
final class HourColumnView: UIView {
    private let hourLabel = SpacedLabel(font: font(22), alpha: 0.6)
    private let tempLabel = SpacedLabel(font: font(38, .semibold))

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Nine columns are narrow on a 768 pt screen; shrink rather than truncate "-12°".
        for label in [hourLabel, tempLabel] {
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.7
        }
        let stack = UIStackView(arrangedSubviews: [hourLabel, tempLabel])
        stack.axis = .vertical
        stack.spacing = 4
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

    /// `color` follows the graph's color for that temperature.
    func configure(hour: String, temperature: String, color: UIColor?) {
        hourLabel.set(hour)
        tempLabel.set(temperature)
        tempLabel.inkOverride = color
    }
}

/// The next hours' temperatures as a line over a faint fill, one point per hour
/// column above it. Tinted by temperature (muted blue for cold, neutral, muted
/// orange to red for hot) so the colors stay quiet next to the rest of the page.
final class TemperatureGraphView: UIView {
    var temperatures: [Double] = [] { didSet { if temperatures != oldValue { setNeedsDisplay() } } }
    private let slots = SummaryPageViewController.hours

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        return CGSize(width: UIView.noIntrinsicMetric, height: 190 * scale)
    }

    override func draw(_ rect: CGRect) {
        guard temperatures.count >= 2, let context = UIGraphicsGetCurrentContext() else { return }
        let inset: CGFloat = 10
        let top = bounds.minY + inset, bottom = bounds.maxY - inset
        // At least 8 °C of range, so a flat day draws a nearly flat line.
        let low = temperatures.min()!, high = temperatures.max()!
        let mid = (low + high) / 2, span = max(high - low, 8) * 1.1
        let tMin = mid - span / 2, tMax = mid + span / 2
        func y(_ t: Double) -> CGFloat { return bottom - CGFloat((t - tMin) / (tMax - tMin)) * (bottom - top) }
        func x(_ i: Int) -> CGFloat { return bounds.minX + (CGFloat(i) + 0.5) * bounds.width / CGFloat(slots) }
        let points = temperatures.enumerated().map { CGPoint(x: x($0.offset), y: y($0.element)) }

        // A vertical gradient where each height has the color of its temperature.
        let steps = 16
        let colors = (0...steps).map { step -> CGColor in
            let t = tMax - (tMax - tMin) * Double(step) / Double(steps)
            return TemperatureGraphView.color(for: t).cgColor
        }
        let locations = (0...steps).map { CGFloat($0) / CGFloat(steps) * (bottom - top) / bounds.height + top / bounds.height }
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors as CFArray, locations: locations) else { return }
        let start = CGPoint(x: 0, y: 0), end = CGPoint(x: 0, y: bounds.height)

        let line = UIBezierPath()
        line.move(to: points[0])
        points.dropFirst().forEach { line.addLine(to: $0) }

        // Faint fill under the line.
        let fill = line.copy() as! UIBezierPath
        fill.addLine(to: CGPoint(x: points.last!.x, y: bounds.maxY))
        fill.addLine(to: CGPoint(x: points[0].x, y: bounds.maxY))
        fill.close()
        context.saveGState()
        fill.addClip()
        context.setAlpha(0.16)
        context.drawLinearGradient(gradient, start: start, end: end, options: [])
        context.restoreGState()

        // The line and the hourly dots.
        context.saveGState()
        context.setLineWidth(4)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.addPath(line.cgPath)
        context.replacePathWithStrokedPath()
        context.clip()
        context.drawLinearGradient(gradient, start: start, end: end, options: [])
        context.restoreGState()
        context.saveGState()
        for p in points { context.addEllipse(in: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)) }
        context.clip()
        context.drawLinearGradient(gradient, start: start, end: end, options: [])
        context.restoreGState()
    }

    /// Muted colors by °C; neutral is the page's own ink, so mild weather stays grey.
    static func color(for celsius: Double) -> UIColor {
        let neutral = ink
        let stops: [(Double, UIColor)] = Theme.isDark ? [
            (-5, UIColor(red: 0.36, green: 0.52, blue: 0.70, alpha: 1)),
            (8, UIColor(red: 0.55, green: 0.64, blue: 0.74, alpha: 1)),
            (16, neutral),
            (25, UIColor(red: 0.78, green: 0.56, blue: 0.36, alpha: 1)),
            (33, UIColor(red: 0.76, green: 0.36, blue: 0.30, alpha: 1)),
        ] : [
            (-5, UIColor(red: 0.20, green: 0.38, blue: 0.60, alpha: 1)),
            (8, UIColor(red: 0.38, green: 0.48, blue: 0.60, alpha: 1)),
            (16, UIColor(white: 0.35, alpha: 1)),
            (25, UIColor(red: 0.72, green: 0.45, blue: 0.22, alpha: 1)),
            (33, UIColor(red: 0.68, green: 0.24, blue: 0.18, alpha: 1)),
        ]
        guard celsius > stops[0].0 else { return dimmed(stops[0].1) }
        for (a, b) in zip(stops, stops.dropFirst()) where celsius <= b.0 {
            return dimmed(mix(a.1, b.1, CGFloat((celsius - a.0) / (b.0 - a.0))))
        }
        return dimmed(stops.last!.1)
    }

    /// The dark theme dims its ink in a dark room; the graph follows.
    private static func dimmed(_ color: UIColor) -> UIColor {
        guard Theme.isDark else { return color }
        let level = (0.45 + 0.37 * AmbientLight.shared.level) / 0.82
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r * level, green: g * level, blue: b * level, alpha: a)
    }

    private static func mix(_ a: UIColor, _ b: UIColor, _ f: CGFloat) -> UIColor {
        var (r1, g1, b1, a1, r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0, 0, 0, 0, 0)
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * f, green: g1 + (g2 - g1) * f, blue: b1 + (b2 - b1) * f, alpha: 1)
    }
}
