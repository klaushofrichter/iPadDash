import UIKit

/// Page 1: the TRMNL "Steps & Claude" design in the top half (steps panel |
/// divider | Claude panel, title bar below). The bottom half is reserved.
final class StepsClaudePageViewController: DashboardPageViewController {
    // Pace depends on the clock, so re-evaluate between fetches too.
    override var redrawInterval: TimeInterval? { return 30 }

    private let service = StepsService()
    private var stepsReading: StepsReading?
    private var claudeReading: ClaudeReading?
    private var stepsError: Error?
    private var claudeError: Error?
    private var demoMode = false

    private let stepsPanel = StepsPanelView()
    private let claudePanel = ClaudePanelView()

    override func viewDidLoad() {
        super.viewDidLoad()

        let divider = InkView()
        let columns = UIStackView(arrangedSubviews: [stepsPanel, divider, claudePanel])
        columns.alignment = .fill
        divider.widthAnchor.constraint(equalToConstant: 2).isActive = true
        stepsPanel.widthAnchor.constraint(equalTo: claudePanel.widthAnchor).isActive = true

        // TRMNL's title bar: plugin name on the left, last update on the right.
        let (rule, titleBar) = addTitleBar("Steps & Claude")
        let reserved = ReservedAreaView(text: "Lower half · reserved")

        for v in [columns, reserved] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            columns.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            columns.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
            columns.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8),
            rule.topAnchor.constraint(equalTo: columns.bottomAnchor, constant: 8),
            // The design ends at the middle of the screen.
            titleBar.bottomAnchor.constraint(equalTo: view.centerYAnchor, constant: -8),
            reserved.topAnchor.constraint(equalTo: view.centerYAnchor, constant: 16),
            reserved.leadingAnchor.constraint(equalTo: rule.leadingAnchor),
            reserved.trailingAnchor.constraint(equalTo: rule.trailingAnchor),
            reserved.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8),
        ])

        #if DEBUG
        // simctl launch ... with SIMCTL_CHILD_IPADDASH_DEMO=1 shows fixed sample data.
        if ProcessInfo.processInfo.environment["IPADDASH_DEMO"] != nil {
            demoMode = true
            let now = Date()
            // IPADDASH_STEPS_AGE=<minutes> sets how old the steps reading is (default 12).
            let stepsAge = ProcessInfo.processInfo.environment["IPADDASH_STEPS_AGE"].flatMap(Double.init) ?? 12
            stepsReading = StepsReading(timestamp: now.addingTimeInterval(-stepsAge * 60), steps: 6_240)
            // IPADDASH_CLAUDE_AGE=<minutes> sets how old the Claude reading is (default 3).
            let claudeAge = ProcessInfo.processInfo.environment["IPADDASH_CLAUDE_AGE"].flatMap(Double.init) ?? 3
            // IPADDASH_CLAUDE_OVERUSE=1 puts both windows well ahead of pace.
            let overuse = ProcessInfo.processInfo.environment["IPADDASH_CLAUDE_OVERUSE"] != nil
            claudeReading = ClaudeReading(timestamp: now.addingTimeInterval(-claudeAge * 60),
                                          session: overuse ? 60 : 41, weekly: overuse ? 55 : 38,
                                          sessionReset: now.addingTimeInterval(3 * 3600),
                                          weeklyReset: now.addingTimeInterval(90 * 3600))
        }
        #endif
        startFetching()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        render()
    }

    override func load(completion: @escaping () -> Void) {
        guard !demoMode else { return completion() }
        let group = DispatchGroup()
        group.enter()
        service.fetchSteps { result in
            switch result {
            case .success(let reading): self.stepsReading = reading; self.stepsError = nil
            case .failure(let error): self.stepsError = error
            }
            group.leave()
        }
        group.enter()
        service.fetchClaude { result in
            switch result {
            case .success(let reading): self.claudeReading = reading; self.claudeError = nil
            case .failure(let error): self.claudeError = error
            }
            group.leave()
        }
        group.notify(queue: .main, execute: completion)
    }

    override func render() {
        let now = Date()
        // Keep showing the last good reading on a failed fetch; its freshness line ages on its own.
        if let reading = stepsReading {
            stepsPanel.configure(with: StepsSummary(reading: reading, now: now))
        } else {
            stepsPanel.showError(stepsError?.localizedDescription ?? "loading…")
        }
        if let reading = claudeReading {
            claudePanel.configure(with: ClaudeSummary(reading: reading, now: now))
        } else {
            claudePanel.showError(claudeError?.localizedDescription ?? "loading…")
        }

        showStatus(error: stepsError ?? claudeError, hasData: stepsReading != nil || claudeReading != nil)
        hasAlert = stepsPanel.alerting || claudePanel.alerting || claudePanel.overuse
    }
}
