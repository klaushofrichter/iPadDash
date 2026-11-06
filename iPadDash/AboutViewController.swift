import UIKit

/// Opened by swiping down on a dashboard page: app info and settings.
/// Closed with Done or by swiping up (iOS 12 has no swipe-to-dismiss).
final class AboutViewController: UIViewController, UITextFieldDelegate {
    private let intervalControl = UISegmentedControl(items: Settings.refreshIntervals.map(intervalText))
    private let themeControl = UISegmentedControl(items: ["Light", "Dark"])
    private let clockControl = UISegmentedControl(items: Settings.clockFormatters.map { $0.string(from: Date()) })
    private let autoMoveControl = UISegmentedControl(
        items: Settings.autoMoveIntervals.map { $0 == 0 ? "None" : intervalText($0) })
    private let ambientControl = UISegmentedControl(
        items: Settings.ambientIntervals.map { $0 == 0 ? "Off" : intervalText($0) })
    private let summaryControl = UISegmentedControl(items: ["Off", "On"])
    private let ambientStatus = SpacedLabel(font: font(14), alpha: 0.6)
    private let plugField = UITextField()
    private let chargeStatus = SpacedLabel(font: font(14), alpha: 0.6)

    override var prefersStatusBarHidden: Bool { return true }

    override func loadView() {
        view = PaperView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        func status(_ keys: String...) -> String {
            return keys.allSatisfy { Secrets.string($0) != nil } ? "configured" : "missing"
        }

        let title = SpacedLabel(font: font(32, .bold), kern: 2)
        title.set("ABOUT")
        let appLine = SpacedLabel(font: font(20))
        appLine.set("iPadDash \(version)")

        intervalControl.selectedSegmentIndex = Settings.refreshIntervals.firstIndex(of: Settings.refreshInterval)!
        intervalControl.addTarget(self, action: #selector(intervalChanged), for: .valueChanged)
        autoMoveControl.selectedSegmentIndex = Settings.autoMoveIntervals.firstIndex(of: Settings.autoMoveInterval)!
        autoMoveControl.addTarget(self, action: #selector(autoMoveChanged), for: .valueChanged)
        summaryControl.selectedSegmentIndex = Settings.summaryPage ? 1 : 0
        summaryControl.addTarget(self, action: #selector(summaryChanged), for: .valueChanged)
        ambientControl.selectedSegmentIndex = Settings.ambientIntervals.firstIndex(of: Settings.ambientInterval)!
        ambientControl.addTarget(self, action: #selector(ambientChanged), for: .valueChanged)
        ambientStatus.textAlignment = .left
        themeControl.selectedSegmentIndex = Theme.isDark ? 1 : 0
        themeControl.addTarget(self, action: #selector(themeChanged), for: .valueChanged)
        clockControl.selectedSegmentIndex = Settings.clockFormat
        clockControl.addTarget(self, action: #selector(clockChanged), for: .valueChanged)

        plugField.text = Settings.chargePlug
        plugField.placeholder = "IP address of the Kasa plug, e.g. 192.168.1.23 (empty: off)"
        plugField.font = font(17)
        plugField.keyboardType = .numbersAndPunctuation
        plugField.autocorrectionType = .no
        plugField.autocapitalizationType = .none
        plugField.returnKeyType = .done
        plugField.clearButtonMode = .whileEditing
        plugField.delegate = self
        plugField.layer.borderWidth = 1
        plugField.layer.cornerRadius = 6
        plugField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        plugField.leftViewMode = .always
        chargeStatus.textAlignment = .left

        let done = UIButton(type: .system)
        done.titleLabel?.font = font(20, .bold)
        done.setTitle("Done", for: .normal)
        done.addTarget(self, action: #selector(close), for: .touchUpInside)
        doneButton = done

        let stack = UIStackView(arrangedSubviews: [
            title, appLine,
            section("Background update interval", control: intervalControl,
                    note: "How often each page fetches new data on its own. A tap or swipe up on a page reloads immediately."),
            section("Auto-move", control: autoMoveControl,
                    note: "Fades to the next page on its own. A page you swipe to stays twice as long, once."),
            section("Summary page", control: summaryControl,
                    note: "Shows only this page; a page you swipe to comes back here after 2× auto-move (or 30 s)."),
            section("Charging plug", control: plugField,
                    note: "Switches this iPad's charger: on at 30 %, off at 80 %. While off, the plug turns itself back on within 2 h unless the app keeps checking.",
                    extra: chargeStatus),
            section("Theme", control: themeControl),
            section("Date and time", control: clockControl,
                    note: "Shown in the lower left corner of every page."),
            section("Ambient light", control: ambientControl,
                    note: "The front camera samples the room to dim screen and background. No images are kept.",
                    extra: ambientStatus),
            section("Data source", lines: ["Steps & Claude: steps.skylar.technology  ·  token \(status("StepsToken"))",
                                           "Cluster: Grafana Cloud (skylar-technology)  ·  token \(status("GrafanaUser", "GrafanaToken"))",
                                           "Uptime: UptimeRobot  ·  key \(status("UptimeRobotKey"))",
                                           "GitHub: klaushofrichter, hourly  ·  token \(status("GitHubToken"))"]),
            section("Gestures", lines: ["Tap: freeze the page for 15 min and reload (red countdown, reloads every minute); again to restart the 15 min",
                                        "Long press: light / dark",
                                        "Swipe left / right: switch page; also ends a freeze",
                                        "Swipe up on a page: reload it",
                                        "Swipe down: this page  ·  swipe up: close"]),
        ])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.setCustomSpacing(8, after: title)

        // Scrolls when it doesn't fit (and when the keyboard covers the lower half).
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = false
        scroll.keyboardDismissMode = .interactive
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        for v in [scroll, done] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            done.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            done.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: guide.topAnchor, constant: 48),
            scroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 48),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -96),
        ])
        scrollView = scroll

        let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(close))
        swipeUp.direction = .up
        view.addGestureRecognizer(swipeUp)
        NotificationCenter.default.addObserver(self, selector: #selector(restyle),
                                               name: Theme.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateAmbientStatus),
                                               name: AmbientLight.didUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateChargeStatus),
                                               name: ChargeControl.didChange, object: nil)
        for (name, selector) in [(UIResponder.keyboardWillShowNotification, #selector(keyboardShown(_:))),
                                 (UIResponder.keyboardWillHideNotification, #selector(keyboardHidden))] {
            NotificationCenter.default.addObserver(self, selector: selector, name: name, object: nil)
        }
        updateAmbientStatus()
        updateChargeStatus()
        restyle()
    }

    private var doneButton: UIButton?
    private var scrollView: UIScrollView?

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        Settings.chargePlug = textField.text ?? ""
        textField.text = Settings.chargePlug
    }

    @objc private func keyboardShown(_ note: Notification) {
        guard let scroll = scrollView,
              let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let overlap = scroll.frame.maxY - view.convert(frame, from: nil).minY
        scroll.contentInset.bottom = max(overlap, 0)
        scroll.scrollRectToVisible(scroll.convert(plugField.bounds, from: plugField).insetBy(dx: 0, dy: -60), animated: true)
    }

    @objc private func keyboardHidden() {
        scrollView?.contentInset.bottom = 0
    }

    @objc private func updateChargeStatus() {
        let charge = ChargeControl.shared
        var parts: [String] = []
        if let battery = charge.batteryText { parts.append("Battery \(battery)") }
        if charge.isOn {
            if let on = charge.plugOn { parts.append("plug \(on ? "on" : "off")") }
            if let error = charge.lastError {
                parts.append("plug: \(error)")
            } else if let contact = charge.lastContact {
                parts.append("checked \(timeOfDayFormatter.string(from: contact))")
            } else {
                parts.append("contacting the plug…")
            }
        } else {
            parts.append("off: the charger stays on")
        }
        parts += charge.alerts.map { "\($0.what) \($0.detail)" }
        chargeStatus.set(parts.joined(separator: " · "))
        chargeStatus.alert = !charge.alerts.isEmpty
    }

    private func section(_ heading: String, control: UIView? = nil, note: String? = nil,
                         lines: [String] = [], extra: UIView? = nil) -> UIView {
        let headingLabel = SpacedLabel(font: font(14, .bold), kern: 1, uppercase: true, alpha: 0.6)
        headingLabel.textAlignment = .left
        headingLabel.set(heading)
        var views: [UIView] = [headingLabel]
        if let control = control {
            control.heightAnchor.constraint(equalToConstant: 34).isActive = true
            views.append(control)
        }
        for text in lines + (note.map { [$0] } ?? []) {
            let label = SpacedLabel(font: font(text == note ? 14 : 15), alpha: text == note ? 0.6 : 1)
            label.textAlignment = .left
            label.numberOfLines = 0
            label.adjustsFontSizeToFitWidth = false
            label.set(text)
            views.append(label)
        }
        if let extra = extra { views.append(extra) }
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = 6
        return stack
    }

    @objc private func intervalChanged() {
        Settings.refreshInterval = Settings.refreshIntervals[intervalControl.selectedSegmentIndex]
    }

    @objc private func autoMoveChanged() {
        Settings.autoMoveInterval = Settings.autoMoveIntervals[autoMoveControl.selectedSegmentIndex]
    }

    @objc private func summaryChanged() {
        Settings.summaryPage = summaryControl.selectedSegmentIndex == 1
    }

    @objc private func ambientChanged() {
        Settings.ambientInterval = Settings.ambientIntervals[ambientControl.selectedSegmentIndex]
        AmbientLight.shared.start()
        updateAmbientStatus()
    }

    @objc private func clockChanged() {
        Settings.clockFormat = clockControl.selectedSegmentIndex
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
        plugField.textColor = ink
        plugField.tintColor = ink
        plugField.layer.borderColor = ink.withAlphaComponent(0.5).cgColor
        plugField.attributedPlaceholder = NSAttributedString(
            string: plugField.placeholder ?? "", attributes: [.foregroundColor: ink.withAlphaComponent(0.4)])
        plugField.keyboardAppearance = Theme.isDark ? .dark : .light
        themeControl.selectedSegmentIndex = Theme.isDark ? 1 : 0
    }

    @objc private func close() {
        view.endEditing(true)
        dismiss(animated: true)
    }
}
