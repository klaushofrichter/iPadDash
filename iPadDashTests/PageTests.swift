import XCTest
@testable import iPadDash

/// A page whose fetch ends when the test says so.
private final class FakePage: DashboardPageViewController {
    private(set) var loads = 0
    private var pending: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        _ = addFullPage(title: "Fake")
        startFetching()
    }

    override func load(completion: @escaping () -> Void) {
        loads += 1
        pending = completion
    }

    func finishLoad() {
        let completion = pending
        pending = nil
        completion?()
    }
}

/// The page templates, reloading, and the summary page's layout.
final class PageTests: XCTestCase {
    /// An iPad Air's screen without the root's footer.
    private let pageSize = CGSize(width: 768, height: 988)

    private func layOut(_ page: UIViewController) {
        page.view.frame = CGRect(origin: .zero, size: pageSize)
        page.view.setNeedsLayout()
        page.view.layoutIfNeeded()
    }

    // MARK: Templates

    func testEveryPageEndsInRuleAndTitleBar() {
        let pages: [DashboardPageViewController] = [
            SummaryPageViewController(), StepsClaudePageViewController(), ClusterPageViewController(),
            UptimePageViewController(), GitHubPageViewController(), NetworkBatteryPageViewController(),
        ]
        for page in pages {
            layOut(page)
            let name = String(describing: type(of: page))
            guard let bar = page.instanceLabel.superview else { return XCTFail("\(name): no title bar") }
            XCTAssertFalse(page.pageName.isEmpty, name)
            XCTAssertEqual(bar.frame.maxY, pageSize.height - 10, accuracy: 1, "\(name): title bar at the bottom")
            XCTAssertEqual(bar.frame.width, pageSize.width - 32, accuracy: 1, name)
            let rules = page.view.subviews.filter { $0 is InkView && abs($0.frame.maxY - (bar.frame.minY - 8)) < 1 }
            XCTAssertEqual(rules.count, 1, "\(name): one rule above the title bar")
            XCTAssertEqual(rules.first?.frame.width ?? 0, pageSize.width - 32, accuracy: 1, name)
        }
    }

    func testSplitPageHasPanelsOverALowerHalf() {
        let page = ClusterPageViewController()
        layOut(page)
        let rules = page.view.subviews.filter { $0 is InkView }.sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(rules.count, 2, "the middle rule and the title bar's")
        guard rules.count == 2, let columns = page.view.subviews.first(where: { $0 is UIStackView && $0.frame.minY < 50 })
        else { return XCTFail("no panels") }
        // The panels end above the middle rule, which sits a little above the middle.
        XCTAssertLessThan(columns.frame.maxY, rules[0].frame.minY)
        XCTAssertLessThan(rules[0].frame.maxY, pageSize.height / 2)
        XCTAssertGreaterThan(rules[0].frame.maxY, pageSize.height / 3)
        // Everything else lies between the two rules.
        for view in page.view.subviews where view !== columns && !(view is InkView) && view.frame.minY > rules[0].frame.minY {
            XCTAssertLessThanOrEqual(view.frame.maxY, rules[1].frame.minY + 40)
        }
    }

    // MARK: Reloading

    func testReloadCompletesAfterTheFetch() {
        let page = FakePage()
        page.loadViewIfNeeded()          // starts the first fetch
        XCTAssertEqual(page.loads, 1)
        var done = 0
        page.reloadNow { done += 1 }     // joins the fetch under way
        XCTAssertEqual(page.loads, 1)
        XCTAssertEqual(done, 0)
        page.finishLoad()
        XCTAssertEqual(done, 1)

        page.reloadNow { done += 1 }     // a fetch of its own
        page.reloadNow { done += 1 }
        XCTAssertEqual(page.loads, 2)
        XCTAssertEqual(done, 1)
        page.finishLoad()
        XCTAssertEqual(done, 3)
        page.finishLoad()                // nothing left to call
        XCTAssertEqual(done, 3)
    }

    func testFailedFetchRetriesSoonOnce() {
        let page = FakePage()
        page.loadViewIfNeeded()
        page.finishLoad()
        XCTAssertEqual(page.loads, 1)
        page.retrySoon()
        page.retrySoon()   // a second failure replaces the first timer
        // Fire the pending timer without waiting two minutes.
        RunLoop.current.run(until: Date())
        XCTAssertEqual(page.loads, 1, "nothing before the delay")
        page.reloadNow()   // a fetch in the meantime cancels the retry
        page.finishLoad()
        XCTAssertEqual(page.loads, 2)
        XCTAssertEqual(DashboardPageViewController.retryAfterFailure, 120)
    }

    func testPlugCheckWithoutPlugCompletesAtOnce() {
        guard !ChargeControl.shared.isOn else { return }   // a plug is set up on this device
        var done = false
        ChargeControl.shared.check { done = true }
        XCTAssertTrue(done)
    }

    func testAlertsPostOnlyOnChange() {
        let page = FakePage()
        var posts = 0
        let token = NotificationCenter.default.addObserver(forName: pageAlertDidChange, object: nil, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        page.alerts = [PageAlert("A", "b")]
        page.alerts = [PageAlert("A", "b")]
        XCTAssertEqual(posts, 1)
        XCTAssertTrue(page.hasAlert)
        page.alerts = []
        XCTAssertEqual(posts, 2)
    }

    func testPageDotHitsTheNearestDot() {
        let dots = PageDotsView(frame: CGRect(x: 0, y: 0, width: 200, height: 15))
        dots.numberOfPages = 5
        // Dots are 11 wide, 14 apart: 5 dots take 111, starting at 44.5; centers 50, 75, 100, 125, 150.
        XCTAssertEqual(dots.page(at: 50), 0)
        XCTAssertEqual(dots.page(at: 100), 2)
        XCTAssertEqual(dots.page(at: 111), 2)
        XCTAssertEqual(dots.page(at: 114), 3)
        XCTAssertEqual(dots.page(at: 150), 4)
        XCTAssertNil(dots.page(at: 20), "left of the first dot")
        XCTAssertNil(dots.page(at: 180), "right of the last dot")
        // Touches a little outside the thin view still count.
        XCTAssertTrue(dots.point(inside: CGPoint(x: 100, y: -12), with: nil))
        XCTAssertFalse(dots.point(inside: CGPoint(x: 100, y: -30), with: nil))
        var selected: Int?
        dots.onSelect = { selected = $0 }
        dots.onSelect?(3)
        XCTAssertEqual(selected, 3)
    }

    func testShowRowsHidesTheRest() {
        let stack = UIStackView(arrangedSubviews: (0..<3).map { _ in KeyValueRow() })
        stack.showRows(["a", "b"]) { (row: KeyValueRow, item) in row.set(item, "x") }
        XCTAssertEqual(stack.arrangedSubviews.map { $0.isHidden }, [false, false, true])
        stack.showRows(["a", "b", "c", "d"], make: { KeyValueRow() }) { (row: KeyValueRow, item) in row.set(item, "x") }
        XCTAssertEqual(stack.arrangedSubviews.count, 4)
        XCTAssertFalse(stack.arrangedSubviews.contains { $0.isHidden })
    }

    // MARK: Summary page

    private func summary(redItems: Int) -> SummaryPageViewController {
        let source = FakePage()
        source.alerts = (0..<redItems).map { PageAlert("Item \($0)", "red") }
        let page = SummaryPageViewController()
        page.sources = [source]
        page.loadViewIfNeeded()
        let now = Date()
        page.forecast = WeatherForecast(hours: (0..<12).map {
            HourlyTemperature(time: now.addingTimeInterval(Double($0) * 3600), celsius: 15 + Double($0))
        })
        return page
    }

    /// The sections shown below the red items after each of several redraws.
    private func sectionCounts(_ page: SummaryPageViewController, passes: Int = 6) -> [Int] {
        return (0..<passes).map { _ in
            page.render()
            layOut(page)
            layOut(page)   // the fit changes the stack; let that settle
            XCTAssertLessThanOrEqual(page.lower.frame.height, page.lowerArea.bounds.height + 0.5,
                                     "clock, date and weather must fit, not be clipped")
            return page.lower.arrangedSubviews.count
        }
    }

    func testSummaryShowsEverythingWithoutRedItems() {
        let page = summary(redItems: 0)
        XCTAssertEqual(sectionCounts(page), Array(repeating: 4, count: 6))
        // With nothing red, the clock area starts where the red items would.
        let withRed = summary(redItems: 2)
        _ = sectionCounts(withRed, passes: 1)
        XCTAssertLessThan(page.lowerArea.frame.minY, withRed.lowerArea.frame.minY)
    }

    func testSummaryWithoutForecastShowsNoGraph() {
        let page = summary(redItems: 0)
        page.forecast = nil
        XCTAssertEqual(sectionCounts(page, passes: 2), [3, 3], "clock, date and the weather note, no graph")
    }

    func testSummaryGoesBackAndForthWithTheRedItems() {
        let source = FakePage()
        let page = SummaryPageViewController()
        page.sources = [source]
        page.loadViewIfNeeded()
        let now = Date()
        page.forecast = WeatherForecast(hours: (0..<12).map {
            HourlyTemperature(time: now.addingTimeInterval(Double($0) * 3600), celsius: 15 + Double($0))
        })
        XCTAssertEqual(sectionCounts(page, passes: 1), [4])
        let clear = page.lowerArea.frame.minY
        source.alerts = (0..<9).map { PageAlert("Item \($0)", "red") }
        XCTAssertLessThan(sectionCounts(page, passes: 1)[0], 4)
        XCTAssertGreaterThan(page.lowerArea.frame.minY, clear)
        source.alerts = []
        XCTAssertEqual(sectionCounts(page, passes: 1), [4], "everything is back once nothing is red")
        XCTAssertEqual(page.lowerArea.frame.minY, clear, accuracy: 0.5)
    }

    /// The clipped clock of November 2026: with many red items the graph was dropped
    /// on one redraw and back, too tall, on the next.
    func testSummaryDropsLowerSectionsAndStaysThatWay() {
        for items in 1...9 {
            let counts = sectionCounts(summary(redItems: items))
            XCTAssertEqual(Set(counts).count, 1, "\(items) red items: the same sections on every redraw, got \(counts)")
            XCTAssertGreaterThanOrEqual(counts[0], 2, "\(items) red items: clock and date always show")
        }
        XCTAssertLessThan(sectionCounts(summary(redItems: 9))[0], 4, "nine red items leave no room for the graph")
    }

    /// A red item without detail ("8 PRs older than 15 minutes") is a full row too.
    func testSummaryShowsRowsWithoutDetail() {
        let source = FakePage()
        let page = SummaryPageViewController()
        page.sources = [source]
        page.loadViewIfNeeded()
        source.alerts = [PageAlert("One", "red"), PageAlert("Two"), PageAlert("Three", "red")]
        _ = sectionCounts(page, passes: 1)
        let rows = descendants(of: page.view).compactMap { $0 as? KeyValueRow }.filter { !$0.isHidden }
        XCTAssertEqual(rows.count, 3)
        for row in rows { XCTAssertGreaterThan(row.frame.height, 20, "row \(row.keyLabel.text ?? "") collapsed") }
    }

    private func descendants(of view: UIView) -> [UIView] {
        return view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
