import UIKit

/// Opened by swiping down on a dashboard page: app info and settings.
/// Closed with Done or by swiping up (iOS 12 has no swipe-to-dismiss).
final class AboutViewController: UIViewController {
    private let intervalControl = UISegmentedControl(items: Settings.refreshIntervals.map(intervalText))
    private let themeControl = UISegmentedControl(items: ["Light", "Dark"])
    private let autoMoveControl = UISegmentedControl(
        items: Settings.autoMoveIntervals.map { $0 == 0 ? "None" : intervalText($0) })
    private let ambientControl = UISegmentedControl(
        items: Settings.ambientIntervals.map { $0 == 0 ? "Off" : intervalText($0) })
    private let ambientStatus = SpacedLabel(font: font(14), alpha: 0.6)

    override var prefersStatusBarHidden: Bool { return true }

    override func loadView() {
        view = PaperView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let tokenStatus = StepsService.tokenFromBundle() == nil ? "missing" : "configured"
        let clusterStatus = ClusterService().hasCredentials ? "configured" : "missing"
        let uptimeStatus = UptimeService().hasKey ? "configured" : "missing"
        let gitHubStatus = GitHubService().hasToken ? "configured" : "missing"

        let title = SpacedLabel(font: font(32, .bold), kern: 2)
        title.set("ABOUT")
        let appLine = SpacedLabel(font: font(20))
        appLine.set("iPadDash \(version) (\(build))")

        intervalControl.selectedSegmentIndex = Settings.refreshIntervals.firstIndex(of: Settings.refreshInterval) ?? 1
        intervalControl.addTarget(self, action: #selector(intervalChanged), for: .valueChanged)
        autoMoveControl.selectedSegmentIndex = Settings.autoMoveIntervals.firstIndex(of: Settings.autoMoveInterval) ?? 0
        autoMoveControl.addTarget(self, action: #selector(autoMoveChanged), for: .valueChanged)
        ambientControl.selectedSegmentIndex = Settings.ambientIntervals.firstIndex(of: Settings.ambientInterval) ?? 2
        ambientControl.addTarget(self, action: #selector(ambientChanged), for: .valueChanged)
        ambientStatus.textAlignment = .left
        themeControl.selectedSegmentIndex = Theme.isDark ? 1 : 0
        themeControl.addTarget(self, action: #selector(themeChanged), for: .valueChanged)

        let done = UIButton(type: .system)
        done.titleLabel?.font = font(20, .bold)
        done.setTitle("Done", for: .normal)
        done.addTarget(self, action: #selector(close), for: .touchUpInside)
        doneButton = done

        let stack = UIStackView(arrangedSubviews: [
            title, appLine,
            section("Background update interval", control: intervalControl,
                    note: "How often each page fetches new data on its own. A tap on a page always reloads immediately."),
            section("Auto-move", control: autoMoveControl,
                    note: "Fades to the next page on its own. A swipe restarts the countdown."),
            section("Theme", control: themeControl, note: "Long press on a page also switches."),
            section("Ambient light", control: ambientControl,
                    note: "Briefly uses the front camera to measure the room and dims the screen and background to match. No images are kept.",
                    extra: ambientStatus),
            section("Data source", lines: ["Steps & Claude: steps.skylar.technology  ·  token \(tokenStatus)",
                                           "Design: klaushofrichter/trmnl-for-steps",
                                           "Cluster: Grafana Cloud (skylar-technology)  ·  token \(clusterStatus)",
                                           "Uptime: UptimeRobot  ·  key \(uptimeStatus)",
                                           "GitHub: klaushofrichter, hourly  ·  token \(gitHubStatus)"]),
            section("Gestures", lines: ["Tap: reload the page",
                                        "Long press: light / dark",
                                        "Swipe left / right: switch page",
                                        "Swipe up on a page: freeze it for 15 min (red countdown, reloads every minute); again to unfreeze",
                                        "Swipe down: this page  ·  swipe up: close"]),
        ])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 28
        stack.setCustomSpacing(8, after: title)

        for v in [stack, done] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            done.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            done.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 48),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 48),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -48),
        ])

        let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(close))
        swipeUp.direction = .up
        view.addGestureRecognizer(swipeUp)
        NotificationCenter.default.addObserver(self, selector: #selector(restyle),
                                               name: Theme.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateAmbientStatus),
                                               name: AmbientLight.didUpdate, object: nil)
        updateAmbientStatus()
        restyle()
    }

    private var doneButton: UIButton?

    private func section(_ heading: String, control: UIView? = nil, note: String? = nil,
                         lines: [String] = [], extra: UIView? = nil) -> UIView {
        let headingLabel = SpacedLabel(font: font(14, .bold), kern: 1, uppercase: true, alpha: 0.6)
        headingLabel.textAlignment = .left
        headingLabel.set(heading)
        var views: [UIView] = [headingLabel]
        if let control = control {
            control.heightAnchor.constraint(equalToConstant: 40).isActive = true
            views.append(control)
        }
        for text in lines + (note.map { [$0] } ?? []) {
            let label = SpacedLabel(font: font(text == note ? 14 : 18), alpha: text == note ? 0.6 : 1)
            label.textAlignment = .left
            label.numberOfLines = 0
            label.adjustsFontSizeToFitWidth = false
            label.set(text)
            views.append(label)
        }
        if let extra = extra { views.append(extra) }
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = 10
        return stack
    }

    @objc private func intervalChanged() {
        Settings.refreshInterval = Settings.refreshIntervals[intervalControl.selectedSegmentIndex]
    }

    @objc private func autoMoveChanged() {
        Settings.autoMoveInterval = Settings.autoMoveIntervals[autoMoveControl.selectedSegmentIndex]
    }

    @objc private func ambientChanged() {
        Settings.ambientInterval = Settings.ambientIntervals[ambientControl.selectedSegmentIndex]
        AmbientLight.shared.start()
        updateAmbientStatus()
    }

    @objc private func updateAmbientStatus() {
        let ambient = AmbientLight.shared
        let text: String
        if !ambient.isOn {
            text = "Off: full brightness colors; screen brightness left to iOS."
        } else if let reason = ambient.unavailableReason {
            text = "Not measuring: \(reason)"
        } else if let lux = ambient.lastLux, let date = ambient.lastReading {
            let time = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
            text = "Last reading \(Int(lux.rounded())) lux at \(time) · level \(Int((ambient.level * 100).rounded()))%"
        } else {
            text = "Waiting for the first reading…"
        }
        ambientStatus.set(text)
    }

    @objc private func themeChanged() {
        Theme.isDark = themeControl.selectedSegmentIndex == 1
    }

    @objc private func restyle() {
        applyTheme(to: view)
        doneButton?.setTitleColor(ink, for: .normal)
        themeControl.selectedSegmentIndex = Theme.isDark ? 1 : 0
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}
