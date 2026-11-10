import UIKit

/// A split page: the TRMNL "Steps & Claude" design on top (steps panel |
/// divider | Claude panel). The lower half is reserved.
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

        let lower = addSplitPage(left: stepsPanel, right: claudePanel, bar: "Steps & Claude")
        fill(lower, with: ReservedAreaView(text: "Lower half · reserved"))

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
        var alerts: [PageAlert] = []
        if stepsPanel.alerting, let r = stepsReading { alerts.append(PageAlert("Steps data", "\(durationText(now.timeIntervalSince(r.timestamp))) old")) }
        if claudePanel.alerting, let r = claudeReading { alerts.append(PageAlert("Claude data", "\(durationText(now.timeIntervalSince(r.timestamp))) old")) }
        if claudePanel.overuse { alerts.append(PageAlert("Claude usage", "ahead of pace")) }
        self.alerts = alerts
    }
}
