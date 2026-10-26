import UIKit

/// Page 1: the TRMNL "Steps & Claude" design in the top half (steps panel |
/// divider | Claude panel, title bar below). The bottom half is reserved.
final class StepsClaudePageViewController: UIViewController, DashboardPage {
    // Pace depends on the clock, so re-evaluate between fetches too.
    private let redrawInterval: TimeInterval = 30

    private let service = StepsService()
    private var stepsReading: StepsReading?
    private var claudeReading: ClaudeReading?
    private var stepsError: Error?
    private var claudeError: Error?
    private var lastFetch: Date?
    private var fetching = false
    private var fetchTimer: Timer?
    private var redrawTimer: Timer?
    private var demoMode = false

    private let stepsPanel = StepsPanelView()
    private let claudePanel = ClaudePanelView()
    private let titleLabel = SpacedLabel(font: font(16, .bold))
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
        let columns = UIStackView(arrangedSubviews: [stepsPanel, divider, claudePanel])
        columns.alignment = .fill
        divider.widthAnchor.constraint(equalToConstant: 2).isActive = true
        stepsPanel.widthAnchor.constraint(equalTo: claudePanel.widthAnchor).isActive = true

        // TRMNL's title bar: plugin name on the left, last update on the right.
        let titleBar = UIStackView(arrangedSubviews: [titleLabel, instanceLabel])
        titleLabel.textAlignment = .left
        instanceLabel.textAlignment = .right
        titleLabel.set("Steps & Claude")
        let rule = InkView()
        let reserved = ReservedAreaView(text: "Lower half · reserved")

        for v in [columns, rule, titleBar, reserved] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let guide = view.safeAreaLayoutGuide
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
            // The design ends at the middle of the screen.
            titleBar.bottomAnchor.constraint(equalTo: view.centerYAnchor, constant: -8),
            reserved.topAnchor.constraint(equalTo: view.centerYAnchor, constant: 16),
            reserved.leadingAnchor.constraint(equalTo: rule.leadingAnchor),
            reserved.trailingAnchor.constraint(equalTo: rule.trailingAnchor),
            reserved.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -48),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: Settings.didChange, object: nil)

        #if DEBUG
        // simctl launch ... with SIMCTL_CHILD_IPADDASH_DEMO=1 shows fixed sample data.
        if ProcessInfo.processInfo.environment["IPADDASH_DEMO"] != nil {
            demoMode = true
            let now = Date()
            stepsReading = StepsReading(timestamp: now.addingTimeInterval(-12 * 60), steps: 6_240)
            claudeReading = ClaudeReading(timestamp: now.addingTimeInterval(-3 * 60), session: 41, weekly: 38,
                                          sessionReset: now.addingTimeInterval(3 * 3600),
                                          weeklyReset: now.addingTimeInterval(90 * 3600))
            lastFetch = now
        }
        #endif
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Catch up after being off screen (another page, the About page) longer than an interval.
        if lastFetch.map({ Date().timeIntervalSince($0) >= Settings.refreshInterval }) ?? true {
            fetch()
        }
        render()
        startTimers()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        fetchTimer?.invalidate()
        redrawTimer?.invalidate()
    }

    func reloadNow() {
        fetch()
        startTimers()   // the next automatic update is a full interval from now
    }

    @objc private func settingsChanged() {
        if view.window != nil { startTimers() }
    }

    private func startTimers() {
        fetchTimer?.invalidate()
        redrawTimer?.invalidate()
        fetchTimer = Timer.scheduledTimer(withTimeInterval: Settings.refreshInterval, repeats: true) { [weak self] _ in
            self?.fetch()
        }
        redrawTimer = Timer.scheduledTimer(withTimeInterval: redrawInterval, repeats: true) { [weak self] _ in
            self?.render()
        }
    }

    private func fetch() {
        guard !fetching, !demoMode else { return }
        fetching = true
        render()
        let group = DispatchGroup()
        group.enter()
        service.fetchSteps { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let reading): self.stepsReading = reading; self.stepsError = nil
                case .failure(let error): self.stepsError = error
                }
                group.leave()
            }
        }
        group.enter()
        service.fetchClaude { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let reading): self.claudeReading = reading; self.claudeError = nil
                case .failure(let error): self.claudeError = error
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            self.fetching = false
            self.lastFetch = Date()
            self.render()
        }
    }

    private func render() {
        let now = Date()
        // Keep showing the last good reading on a failed fetch; its freshness line ages on its own.
        if let reading = stepsReading {
            stepsPanel.configure(with: StepsSummary(reading: reading, now: now))
        } else {
            stepsPanel.showError(stepsError.map(errorText) ?? "loading…")
        }
        if let reading = claudeReading {
            claudePanel.configure(with: ClaudeSummary(reading: reading, now: now))
        } else {
            claudePanel.showError(claudeError.map(errorText) ?? "loading…")
        }

        var instance = lastFetch.map { "updated \(timeFormatter.string(from: $0))" } ?? ""
        if fetching {
            instance = "refreshing…"
        } else if let error = stepsError ?? claudeError, stepsReading != nil || claudeReading != nil {
            instance = "fetch failed: \(errorText(error)) · " + instance
        }
        instanceLabel.set(instance)
    }

    private func errorText(_ error: Error) -> String {
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
