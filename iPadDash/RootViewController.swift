import UIKit

/// Hosts the dashboard pages and the global gestures:
///   swipe left/right  next/previous page
///   tap               freeze the current page for 15 minutes and reload it (again: restart the 15 minutes)
///   long press        switch between light and dark
///   swipe down        Settings page
///   swipe up          reload everything on the current page
/// With auto-move on, it also cross-fades to the next page every N seconds; a page
/// reached by a swipe stays for 2N first, since it is probably of interest.
/// A frozen page doesn't auto-move and reloads every minute; the countdown turns
/// red and runs over the freeze. Swiping to another page also unfreezes.
/// A red banner along the bottom, on every page, reports a lost network.
/// With the summary page on (Settings.summaryPage), it is the first page and the
/// only one shown: no auto-move there, and a page swiped to fades back to it after
/// twice the auto-move time (15 s when auto-move is None).
/// A page marked `onlyWhenRed` (Network & Battery) is in the rotation and has a dot
/// only while it is red, or while it is showing.
final class RootViewController: UIViewController, UIPageViewControllerDataSource,
    UIPageViewControllerDelegate, UIGestureRecognizerDelegate {

    private let networkBattery = NetworkBatteryPageViewController()
    private lazy var dataPages: [DashboardPageViewController] = [StepsClaudePageViewController(), ClusterPageViewController(),
                                                              UptimePageViewController(), GitHubPageViewController(),
                                                              networkBattery]
    private let summary = SummaryPageViewController()
    /// The pages in the rotation: the data pages, after the summary page when it is on,
    /// without those shown only when red that aren't.
    private var pages: [DashboardPageViewController] = []
    private var summaryMode: Bool { return pages.first === summary }
    private let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
    private let dots = PageDotsView()
    private let slideFromTop = SlideFromTopTransition()
    private var autoMoveTimer: Timer?
    private let countdown = CountdownView()
    private let footerHeight: CGFloat = 36
    private let freezeDuration: TimeInterval = 15 * 60
    private let frozenReloadInterval: TimeInterval = 60
    /// Set while the current page is frozen; kept by wall clock across the Settings page.
    private var frozenUntil: Date?
    private var frozenReloadTimer: Timer?
    private let clock = SpacedLabel(font: UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular))
    /// "Refreshing…" with a spinner while a tap or swipe up reloads, then "Updated".
    private let toast = UIView()
    private let toastLabel = UILabel()
    private let toastSpinner = UIActivityIndicatorView(style: .white)
    /// Counts reloads and their ends, so only the latest reload ends the toast, once.
    private var reloadCount = 0
    private let reloadTimeout: TimeInterval = 45
    /// On the summary page, where no countdown runs, the battery takes its place.
    private let battery = BatteryIconView()
    private let banner = UILabel()
    private lazy var bannerHeight = banner.heightAnchor.constraint(equalToConstant: 0)
    private let bannerShownHeight: CGFloat = 44

    override var prefersStatusBarHidden: Bool { return true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { return .portrait }

    override func loadView() {
        view = PaperView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        pager.dataSource = self
        pager.delegate = self
        applyPageSet()
        addChild(pager)
        view.addSubview(pager.view)
        pager.didMove(toParent: self)

        // Footer strip below the pages: date and time at the left, page dots centered,
        // auto-move countdown at the right, or the battery on the summary page.

        clock.textAlignment = .left
        banner.textAlignment = .center
        banner.font = font(20, .bold)
        banner.clipsToBounds = true

        toastLabel.font = font(22, .semibold)
        let toastContent = UIStackView(arrangedSubviews: [toastSpinner, toastLabel])
        toastContent.spacing = 12
        toastContent.alignment = .center
        toastContent.translatesAutoresizingMaskIntoConstraints = false
        toast.addSubview(toastContent)
        toast.layer.cornerRadius = 26
        toast.alpha = 0
        toast.isUserInteractionEnabled = false
        for v in [pager.view!, clock, dots, countdown, battery, banner, toast] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        view.addSubview(clock)
        view.addSubview(dots)
        view.addSubview(countdown)
        view.addSubview(battery)
        view.addSubview(banner)
        view.addSubview(toast)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            pager.view.topAnchor.constraint(equalTo: view.topAnchor),
            pager.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pager.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pager.view.bottomAnchor.constraint(equalTo: banner.topAnchor, constant: -footerHeight),
            clock.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            clock.centerYAnchor.constraint(equalTo: dots.centerYAnchor),
            clock.trailingAnchor.constraint(lessThanOrEqualTo: dots.leadingAnchor, constant: -12),
            dots.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            dots.centerYAnchor.constraint(equalTo: banner.topAnchor, constant: -footerHeight / 2),
            // Same right margin as the pages' content and rules.
            countdown.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            countdown.centerYAnchor.constraint(equalTo: dots.centerYAnchor),
            battery.trailingAnchor.constraint(equalTo: countdown.trailingAnchor),
            battery.centerYAnchor.constraint(equalTo: dots.centerYAnchor),
            battery.widthAnchor.constraint(equalToConstant: 34),
            battery.heightAnchor.constraint(equalToConstant: 16),
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            // Above the pages' rule and title bar.
            toast.bottomAnchor.constraint(equalTo: pager.view.bottomAnchor, constant: -76),
            toast.heightAnchor.constraint(equalToConstant: 52),
            toastContent.centerYAnchor.constraint(equalTo: toast.centerYAnchor),
            toastContent.leadingAnchor.constraint(equalTo: toast.leadingAnchor, constant: 24),
            toastContent.trailingAnchor.constraint(equalTo: toast.trailingAnchor, constant: -24),
            banner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            banner.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            bannerHeight,
        ])

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        longPress.minimumPressDuration = 0.6
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.require(toFail: longPress)
        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(showAbout))
        swipeDown.direction = .down
        let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(reloadCurrentPage))
        swipeUp.direction = .up
        for recognizer in [longPress, tap, swipeDown, swipeUp] as [UIGestureRecognizer] {
            recognizer.delegate = self
            view.addGestureRecognizer(recognizer)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: Theme.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updatePages),
                                               name: pageAlertDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateBanner),
                                               name: Connectivity.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateBattery),
                                               name: ChargeControl.didChange, object: nil)
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateBanner()
        }
        // Fires on the whole second, so the display never lags the real time by much.
        let tick = Timer(fire: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.up)),
                         interval: 1, repeats: true) { [weak self] _ in
            self?.updateClock()
        }
        RunLoop.main.add(tick, forMode: .common)
        updateClock()
        // Load every page now so all of them fetch in the background and can flag
        // red markup on their dot before they are first shown.
        dataPages.forEach { _ = $0.view }
        summary.sources = dataPages   // after loading: the summary shows their names
        summary.openPage = { [weak self] page in self?.open(page) }
        updatePages()
        updateBanner()
        applyTheme(to: view)
        AmbientLight.shared.start()
        BatteryHistory.shared.start()
        ChargeControl.shared.start()
        DispatchQueue.main.async { NightScreen.shared.start() }   // once the main window is up
    }

    /// When the Settings page last closed: a touch landing as it slides away
    /// shouldn't freeze the page underneath.
    private var settingsClosedAt = Date.distantPast

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        settingsClosedAt = Date()
    }

    // The Settings page is full screen, so these also pause auto-move while it is open.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyPageSet()
        restartAutoMove()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopAutoMove()
    }

    private func stopAutoMove() {
        autoMoveTimer?.invalidate()
        autoMoveTimer = nil
        frozenReloadTimer?.invalidate()
        frozenReloadTimer = nil
        countdown.stop()
        updateBattery()
    }

    /// Shown on the summary page while no countdown runs: red below 30 %, green
    /// above 70 %, with a bolt while charging.
    @objc private func updateBattery() {
        let charge = ChargeControl.shared
        battery.isHidden = currentPage !== summary || !countdown.isHidden || charge.batteryLevel == nil
        guard !battery.isHidden, let level = charge.batteryLevel else { return }
        battery.level = CGFloat(level)
        battery.charging = charge.isPowered
        battery.fillColor = level < 0.30 ? alertInk : level > 0.70 ? goodInk : nil
    }

    // MARK: - Auto-move

    /// Starts the countdown over (full circle), doubled if the page was just swiped
    /// to. Called on appear (also after the Settings page changed a setting), on a tap
    /// and after a manual swipe. While frozen, it runs the rest of the freeze instead.
    private func restartAutoMove(swiped: Bool = false) {
        stopAutoMove()
        defer { updateBattery() }
        guard view.window != nil, presentedViewController == nil else { return }

        if let until = frozenUntil, until > Date() {
            let remaining = until.timeIntervalSinceNow
            countdown.frozen = true
            countdown.restart(interval: freezeDuration, elapsed: freezeDuration - remaining)
            autoMoveTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
                self?.frozenUntil = nil
                self?.restartAutoMove()   // back to the normal cycle, starting full
            }
            frozenReloadTimer = Timer.scheduledTimer(withTimeInterval: frozenReloadInterval, repeats: true) { [weak self] _ in
                self?.pagesToReload.forEach { $0.reloadNow() }
            }
            return
        }
        frozenUntil = nil
        countdown.frozen = false
        if summaryMode {
            // Home stays put; any other page goes back to it once.
            guard currentPage !== summary else { return }
            let interval = Settings.summaryReturnInterval
            let delay = swiped ? 2 * interval : interval
            countdown.doubled = swiped
            countdown.restart(interval: delay)
            autoMoveTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.fade(to: self.summary)
                self.restartAutoMove()
            }
            return
        }
        let interval = Settings.autoMoveInterval
        guard interval > 0 else { return }
        let firstDelay = swiped ? 2 * interval : interval
        countdown.doubled = swiped
        countdown.restart(interval: firstDelay)
        scheduleAutoMove(after: firstDelay, interval: interval)
    }

    private func scheduleAutoMove(after delay: TimeInterval, interval: TimeInterval) {
        autoMoveTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self, let current = self.currentPage, let index = self.pages.firstIndex(of: current) else { return }
            self.fade(to: self.pages[(index + 1) % self.pages.count])
            self.countdown.nextCycle(interval: interval)
            self.scheduleAutoMove(after: interval, interval: interval)
        }
    }

    /// Cross-fade: freeze the current page in a snapshot, switch pages underneath
    /// without animation, then fade the snapshot out.
    private func fade(to next: DashboardPageViewController) {
        guard let snapshot = pager.view.snapshotView(afterScreenUpdates: false) else { return }
        snapshot.frame = pager.view.frame
        snapshot.isUserInteractionEnabled = false
        view.insertSubview(snapshot, aboveSubview: pager.view)
        pager.setViewControllers([next], direction: .forward, animated: false)
        updatePages()   // a red-only page left behind may drop out; `next` may join
        UIView.animate(withDuration: 1.6, delay: 0, options: .curveEaseInOut, animations: {
            snapshot.alpha = 0
        }, completion: { _ in
            snapshot.removeFromSuperview()
        })
    }

    /// Puts the summary page in or out of the rotation to match the setting; with it
    /// on, shows it. Called at start and when returning from the Settings page.
    private func applyPageSet() {
        let summaryChanged = pages.isEmpty || summaryMode != Settings.summaryPage
        updatePages()
        guard summaryChanged else { return }
        let current = currentPage.flatMap { pages.contains($0) ? $0 : nil }
        let shown = summaryMode ? summary : current ?? pages[0]
        pager.setViewControllers([shown], direction: .forward, animated: false)
        updatePages()
    }

    /// Recomputes the rotation (summary setting, red-only pages) and the dots,
    /// without changing the page shown.
    @objc private func updatePages() {
        let shown = currentPage
        let data = dataPages.filter { !$0.onlyWhenRed || $0.hasAlert || $0 === shown }
        let wanted = Settings.summaryPage ? [summary] + data : data
        if wanted != pages {
            pages = wanted
            dots.numberOfPages = pages.count
        }
        dots.currentPage = shown.flatMap { pages.firstIndex(of: $0) } ?? 0
        dots.alerts = pages.map { $0.hasAlert }
    }

    private var currentPage: DashboardPageViewController? {
        return pager.viewControllers?.first as? DashboardPageViewController
    }

    private func updateClock() {
        let time = Settings.clockFormatters[Settings.clockFormat].string(from: Date())
        clock.set(time)
    }

    @objc private func updateBanner() {
        banner.backgroundColor = alertInk
        banner.textColor = Theme.isDark ? .black : .white
        guard let offline = Connectivity.shared.outage else {
            bannerHeight.constant = 0
            return
        }
        banner.text = "No Network Connectivity for \(durationText(offline))"
        bannerHeight.constant = bannerShownHeight
    }

    // Off-screen pages aren't in the view tree, so theme them explicitly.
    @objc private func themeChanged() {
        updateBanner()
        updateBattery()   // green and red differ by theme
        battery.setNeedsDisplay()
        applyTheme(to: view)
        // All pages, including those out of the rotation right now.
        ([summary] + dataPages).filter { $0.isViewLoaded }.forEach { applyTheme(to: $0.view) }
    }

    // MARK: - Gestures

    @objc private func tapped() {
        guard Date().timeIntervalSince(settingsClosedAt) > 1 else { return }
        frozenUntil = Date().addingTimeInterval(freezeDuration)
        restartAutoMove()
        reloadCurrentPage()
    }

    /// Fades to `page` as if swiped to: unfrozen, with the doubled countdown.
    private func open(_ page: DashboardPageViewController) {
        guard page !== currentPage else { return }
        fade(to: page)
        frozenUntil = nil
        restartAutoMove(swiped: true)
    }

    /// Reloads the page (on the summary page, every page it lists) and asks the
    /// charging plug, with the toast showing until all the answers are in.
    @objc private func reloadCurrentPage() {
        let reloading = pagesToReload
        guard !reloading.isEmpty else { return }
        reloadCount += 1
        let count = reloadCount
        showToast(reloading.count > 1 ? "Refreshing all pages…" : "Refreshing…", busy: true)
        let group = DispatchGroup()
        for page in reloading {
            group.enter()
            page.reloadNow { group.leave() }
        }
        // A fetch that never ends (an unanswered permission prompt) must not keep the toast up.
        DispatchQueue.main.asyncAfter(deadline: .now() + reloadTimeout) { [weak self] in
            guard let self = self, count == self.reloadCount else { return }
            self.reloadCount += 1
            self.endToast("Some data has not arrived yet", after: 3)
        }
        // The charging plug too, if one is set up: its answer shows it is still reachable.
        let charge = ChargeControl.shared
        group.enter()
        charge.check { group.leave() }
        group.notify(queue: .main) { [weak self] in
            guard let self = self, count == self.reloadCount else { return }
            self.reloadCount += 1   // the timeout has nothing left to do
            let plugFailed = charge.isOn && charge.lastError != nil
            self.endToast(plugFailed ? "Updated · charging plug not reachable" : "Updated", after: plugFailed ? 3 : 1.2)
        }
    }

    /// What a reload of the current page covers: on the summary page also the pages
    /// whose red items it shows.
    private var pagesToReload: [DashboardPageViewController] {
        guard let page = currentPage else { return [] }
        return page === summary ? [summary] + summary.sources : [page]
    }

    /// The toast's last word, fading out after `delay`.
    private func endToast(_ text: String, after delay: TimeInterval) {
        showToast(text, busy: false)
        UIView.animate(withDuration: 0.6, delay: delay, options: [.beginFromCurrentState], animations: {
            self.toast.alpha = 0
        })
    }

    private func showToast(_ text: String, busy: Bool) {
        toast.layer.removeAllAnimations()
        toast.backgroundColor = ink.withAlphaComponent(0.9)
        toastLabel.textColor = paper
        toastSpinner.color = paper
        toastLabel.text = text
        if busy { toastSpinner.startAnimating() } else { toastSpinner.stopAnimating() }
        UIView.animate(withDuration: 0.2) { self.toast.alpha = 1 }
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        Theme.isDark.toggle()
    }

    @objc private func showAbout() {
        guard presentedViewController == nil else { return }
        let about = AboutViewController()
        // Shown even when out of the rotation (red only), until its countdown ends.
        about.showBatteryPage = { [weak self] in
            guard let self = self else { return }
            self.open(self.networkBattery)
        }
        about.modalPresentationStyle = .fullScreen   // iOS 13+ would default to a sheet
        about.transitioningDelegate = slideFromTop  // pulled down from the top, like the swipe
        present(about, animated: true)
    }

    // A tap on something with its own tap action (a red row on the summary page)
    // does that instead of freezing the page.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer is UITapGestureRecognizer else { return true }
        var candidate = touch.view
        while let v = candidate, v !== view {
            if v.gestureRecognizers?.contains(where: { $0 is UITapGestureRecognizer && $0.isEnabled }) == true {
                return false
            }
            candidate = v.superview
        }
        return true
    }

    // The page scroll view's pan must not swallow the vertical swipe.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return true
    }

    // MARK: - Paging (carousel: the ends wrap around)

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let index = pages.firstIndex(where: { $0 === viewController }) else { return nil }
        return pages[(index + pages.count - 1) % pages.count]
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let index = pages.firstIndex(where: { $0 === viewController }) else { return nil }
        return pages[(index + 1) % pages.count]
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        updatePages()
        if completed {   // a manual swipe unfreezes and restarts the countdown, doubled
            frozenUntil = nil
            restartAutoMove(swiped: true)
        }
    }
}
