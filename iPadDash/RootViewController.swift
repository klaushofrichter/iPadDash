import UIKit

/// Hosts the dashboard pages and the global gestures:
///   swipe left/right  next/previous page
///   tap               reload everything on the current page
///   long press        switch between light and dark
///   swipe down        About page (settings)
/// With auto-move on, it also cross-fades to the next page every N seconds.
final class RootViewController: UIViewController, UIPageViewControllerDataSource,
    UIPageViewControllerDelegate, UIGestureRecognizerDelegate {

    private let pages: [UIViewController] = [StepsClaudePageViewController(), DemoPageViewController()]
    private let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
    private let dots = UIPageControl()
    private let slideFromTop = SlideFromTopTransition()
    private var autoMoveTimer: Timer?

    override var prefersStatusBarHidden: Bool { return true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { return .portrait }

    override func loadView() {
        view = PaperView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        pager.dataSource = self
        pager.delegate = self
        pager.setViewControllers([pages[0]], direction: .forward, animated: false)
        addChild(pager)
        pager.view.frame = view.bounds
        pager.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pager.view)
        pager.didMove(toParent: self)

        dots.numberOfPages = pages.count
        dots.isUserInteractionEnabled = false
        dots.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dots)
        NSLayoutConstraint.activate([
            dots.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            dots.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        longPress.minimumPressDuration = 0.6
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.require(toFail: longPress)
        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(showAbout))
        swipeDown.direction = .down
        for recognizer in [longPress, tap, swipeDown] as [UIGestureRecognizer] {
            recognizer.delegate = self
            view.addGestureRecognizer(recognizer)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: Theme.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(restartAutoMove),
                                               name: Settings.didChange, object: nil)
        applyTheme(to: view)
    }

    // The About page is full screen, so these also pause auto-move while it is open.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        restartAutoMove()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        autoMoveTimer?.invalidate()
        autoMoveTimer = nil
    }

    // MARK: - Auto-move

    @objc private func restartAutoMove() {
        autoMoveTimer?.invalidate()
        autoMoveTimer = nil
        let interval = Settings.autoMoveInterval
        guard interval > 0, pages.count > 1, view.window != nil, presentedViewController == nil else { return }
        autoMoveTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.fadeToNextPage()
        }
    }

    /// Cross-fade: freeze the current page in a snapshot, switch pages underneath
    /// without animation, then fade the snapshot out.
    private func fadeToNextPage() {
        guard let current = pager.viewControllers?.first, let index = pages.firstIndex(of: current),
              let snapshot = pager.view.snapshotView(afterScreenUpdates: false) else { return }
        let next = (index + 1) % pages.count
        snapshot.frame = pager.view.frame
        snapshot.isUserInteractionEnabled = false
        view.insertSubview(snapshot, aboveSubview: pager.view)
        pager.setViewControllers([pages[next]], direction: .forward, animated: false)
        dots.currentPage = next
        UIView.animate(withDuration: 0.8, delay: 0, options: .curveEaseInOut, animations: {
            snapshot.alpha = 0
        }, completion: { _ in
            snapshot.removeFromSuperview()
        })
    }

    // Off-screen pages aren't in the view tree, so theme them explicitly.
    @objc private func themeChanged() {
        applyTheme(to: view)
        pages.filter { $0.isViewLoaded }.forEach { applyTheme(to: $0.view) }
    }

    // MARK: - Gestures

    @objc private func tapped() {
        (pager.viewControllers?.first as? DashboardPage)?.reloadNow()
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        Theme.isDark.toggle()
    }

    @objc private func showAbout() {
        guard presentedViewController == nil else { return }
        let about = AboutViewController()
        about.modalPresentationStyle = .fullScreen   // iOS 13+ would default to a sheet
        about.transitioningDelegate = slideFromTop  // pulled down from the top, like the swipe
        present(about, animated: true)
    }

    // The page scroll view's pan must not swallow the vertical swipe.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return true
    }

    // MARK: - Paging (carousel: the ends wrap around)

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard pages.count > 1, let index = pages.firstIndex(of: viewController) else { return nil }
        return pages[(index + pages.count - 1) % pages.count]
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard pages.count > 1, let index = pages.firstIndex(of: viewController) else { return nil }
        return pages[(index + 1) % pages.count]
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        if let current = pager.viewControllers?.first, let index = pages.firstIndex(of: current) {
            dots.currentPage = index
        }
        if completed { restartAutoMove() }   // a manual swipe restarts the countdown
    }
}
