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
        XCTAssertEqual(sectionCounts(summary(redItems: 0)), Array(repeating: 4, count: 6))
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
}
