import XCTest
@testable import iPadDash

/// The pace math and the texts made from numbers and ages.
final class ModelTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()

    private func time(_ hour: Int, _ minute: Int = 0) -> Date {
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: hour, minute: minute))!
    }

    // MARK: Texts

    func testDurationText() {
        XCTAssertEqual(durationText(-5), "0 minutes")
        XCTAssertEqual(durationText(59), "0 minutes")
        XCTAssertEqual(durationText(60), "1 minute")
        XCTAssertEqual(durationText(25 * 60), "25 minutes")
        XCTAssertEqual(durationText(3600), "1 hour")
        XCTAssertEqual(durationText(8 * 3600 + 120), "8 hours")
        XCTAssertEqual(durationText(24 * 3600), "1 day")
        XCTAssertEqual(durationText(3 * 24 * 3600), "3 days")
    }

    func testAgeText() {
        XCTAssertEqual(ageText(-10), "0 min")
        XCTAssertEqual(ageText(38 * 60), "38 min")
        XCTAssertEqual(ageText(6 * 3600), "6 h")
        XCTAssertEqual(ageText(47 * 3600), "47 h")
        XCTAssertEqual(ageText(2 * 86400), "2 d")
    }

    func testFreshnessText() {
        let now = time(12)
        XCTAssertEqual(freshnessText(since: now.addingTimeInterval(60), now: now), "updated just now")
        XCTAssertEqual(freshnessText(since: now.addingTimeInterval(-4 * 60), now: now), "updated just now")
        XCTAssertEqual(freshnessText(since: now.addingTimeInterval(-12 * 60), now: now), "updated 12 min ago")
        XCTAssertEqual(freshnessText(since: now.addingTimeInterval(-3600), now: now), "updated 1 hour ago")
        XCTAssertEqual(freshnessText(since: now.addingTimeInterval(-3 * 3600), now: now), "updated 3 hours ago")
        XCTAssertEqual(freshnessText(since: now.addingTimeInterval(-6 * 3600), now: now), "DATA IS OUTDATED")
    }

    func testCounted() {
        XCTAssertEqual(counted(0, "PR"), "0 PRs")
        XCTAssertEqual(counted(1, "PR"), "1 PR")
        XCTAssertEqual(counted(2, "open pull request"), "2 open pull requests")
    }

    func testNumbers() {
        XCTAssertEqual(groupedNumber(1314), "1,314")
        XCTAssertEqual(groupedNumber(7), "7")
        XCTAssertEqual(percentText(41), "41")
        XCTAssertEqual(percentText(41.25), "41.2")
    }

    // MARK: Steps

    func testStepsPaceFollowsTheWindow() {
        func pace(_ hour: Int, _ minute: Int = 0) -> Int {
            let now = time(hour, minute)
            return StepsSummary(reading: StepsReading(timestamp: now, steps: 0), now: now, calendar: calendar).pacePct
        }
        XCTAssertEqual(pace(5), 0)          // before 6:00
        XCTAssertEqual(pace(6), 0)
        XCTAssertEqual(pace(13, 30), 50)    // half of 6:00–21:00
        XCTAssertEqual(pace(21), 100)
        XCTAssertEqual(pace(23), 100)       // after the window
    }

    func testStepsStatusAndHero() {
        let now = time(13, 30)   // pace 50 %
        func summary(_ steps: Int) -> StepsSummary {
            return StepsSummary(reading: StepsReading(timestamp: now, steps: steps), now: now, calendar: calendar)
        }
        XCTAssertEqual(summary(5_300).status, "Ahead of pace")
        XCTAssertEqual(summary(5_200).status, "On pace")       // within 2 points
        XCTAssertEqual(summary(4_800).status, "On pace")
        XCTAssertEqual(summary(4_700).status, "Behind pace")
        XCTAssertEqual(summary(4_455).hero, "5,600 to go")     // rounded up to the next 100
        XCTAssertEqual(summary(11_150).hero, "1,200 above")
        XCTAssertEqual(summary(11_150).actualPct, 112)         // not capped here
    }

    func testStepsStaleAfter130Minutes() {
        let now = time(12)
        func stale(_ minutes: Double) -> Bool {
            let reading = StepsReading(timestamp: now.addingTimeInterval(-minutes * 60), steps: 100)
            return StepsSummary(reading: reading, now: now, calendar: calendar).stale
        }
        XCTAssertFalse(stale(130))
        XCTAssertTrue(stale(131))
    }

    // MARK: Claude

    func testUsageWindowVerdicts() {
        let now = time(12)
        func window(actual: Double?, hoursLeft: Double?) -> UsageWindow {
            return UsageWindow(name: "Session", actual: actual,
                               reset: hoursLeft.map { now.addingTimeInterval($0 * 3600) }, windowHours: 5, now: now)
        }
        // 2.5 of 5 hours left: pace 50 %.
        XCTAssertEqual(window(actual: 60, hoursLeft: 2.5).status, "Overuse")
        XCTAssertTrue(window(actual: 60, hoursLeft: 2.5).overuse)
        XCTAssertEqual(window(actual: 51, hoursLeft: 2.5).status, "On pace")
        XCTAssertEqual(window(actual: 4, hoursLeft: 2.5).status, "Underuse")
        XCTAssertEqual(window(actual: 4, hoursLeft: 2.5).caption, "pace 50% / actual 4%")
        // The reset instant is still a live window; past it, the window has ended.
        XCTAssertFalse(window(actual: 90, hoursLeft: 0).expired)
        let ended = window(actual: 90, hoursLeft: -1)
        XCTAssertTrue(ended.expired)
        XCTAssertEqual(ended.status, "Expired")
        XCTAssertEqual(ended.caption, "window ended / actual 90%")
        // Nothing reported.
        XCTAssertFalse(window(actual: nil, hoursLeft: 2).available)
        XCTAssertFalse(window(actual: 10, hoursLeft: nil).available)
    }

    func testClaudeHero() {
        let now = time(12)
        func hero(weekly: Double?, hoursLeft: Double) -> String {
            let reading = ClaudeReading(timestamp: now, session: 10, weekly: weekly,
                                        sessionReset: now.addingTimeInterval(3600),
                                        weeklyReset: now.addingTimeInterval(hoursLeft * 3600))
            return ClaudeSummary(reading: reading, now: now).hero
        }
        XCTAssertEqual(hero(weekly: 36, hoursLeft: 84), "14% Underuse")   // pace 50 %
        XCTAssertEqual(hero(weekly: 60, hoursLeft: 84), "10% Overuse")
        XCTAssertEqual(hero(weekly: 80, hoursLeft: -2), "80% used")
        XCTAssertEqual(hero(weekly: nil, hoursLeft: 84), "n/a")
    }

    func testClaudeAlertsNameTheWindow() {
        let now = time(12)
        // Session: 2.5 of 5 h left = pace 50 %. Weekly: 84 of 168 h left = pace 50 %.
        func alerts(session: Double?, weekly: Double?) -> [PageAlert] {
            let reading = ClaudeReading(timestamp: now, session: session, weekly: weekly,
                                        sessionReset: now.addingTimeInterval(2.5 * 3600),
                                        weeklyReset: now.addingTimeInterval(84 * 3600))
            return ClaudeSummary(reading: reading, now: now).usageAlerts
        }
        XCTAssertEqual(alerts(session: 40, weekly: 40), [])
        XCTAssertEqual(alerts(session: 60, weekly: 40), [PageAlert("Claude Session Usage", "60% · pace 50%")])
        XCTAssertEqual(alerts(session: 40, weekly: 72.5), [PageAlert("Claude Weekly Usage", "72.5% · pace 50%")])
        XCTAssertEqual(alerts(session: 60, weekly: 55), [PageAlert("Claude Session Usage", "60% · pace 50%"),
                                                         PageAlert("Claude Weekly Usage", "55% · pace 50%")])
        XCTAssertEqual(alerts(session: nil, weekly: 60).map { $0.what }, ["Claude Weekly Usage"])
    }

    func testSettingsSwipeUpClosesOnlyAtTheEnd() {
        // The content fits: any swipe up closes.
        XCTAssertTrue(AboutViewController.isAtEnd(offset: 0, content: 800, visible: 900))
        // Longer than the screen: first scroll to the end.
        XCTAssertFalse(AboutViewController.isAtEnd(offset: 0, content: 1200, visible: 900))
        XCTAssertFalse(AboutViewController.isAtEnd(offset: 150, content: 1200, visible: 900))
        XCTAssertTrue(AboutViewController.isAtEnd(offset: 300, content: 1200, visible: 900))
    }

    // MARK: Network helpers

    func testKasaScrambleRoundTrip() {
        let plain = Data(#"{"system":{"get_sysinfo":{}}}"#.utf8)
        let scrambled = KasaPlug.scramble(plain)
        XCTAssertNotEqual(scrambled, plain)
        // The first byte is the key 171 XOR "{".
        XCTAssertEqual(scrambled.first, 171 ^ UInt8(ascii: "{"))
        XCTAssertEqual(KasaPlug.unscramble(scrambled), plain)
        XCTAssertEqual(KasaPlug.unscramble(KasaPlug.scramble(Data())), Data())
    }

    func testPlugSettingIsNameOrAddress() {
        XCTAssertTrue(KasaSearch.isAddress("192.168.1.34"))
        XCTAssertFalse(KasaSearch.isAddress("Garland"))
        XCTAssertFalse(KasaSearch.isAddress("Window lights"))
        XCTAssertFalse(KasaSearch.isAddress("192.168.1"))
        XCTAssertFalse(KasaSearch.isAddress("192.168.1.300"))
        XCTAssertFalse(KasaSearch.isAddress("192.168..34"))
        XCTAssertFalse(KasaSearch.isAddress(""))
    }

    func testPlugSearchCoversTheNetworkButNotItself() {
        let hosts = KasaSearch.neighbors(of: "192.168.1.107")
        XCTAssertEqual(hosts.count, 253)
        XCTAssertEqual(hosts.first, "192.168.1.1")
        XCTAssertEqual(hosts.last, "192.168.1.254")
        XCTAssertFalse(hosts.contains("192.168.1.107"))
        XCTAssertTrue(hosts.contains("192.168.1.34"))
        XCTAssertEqual(KasaSearch.neighbors(of: "not an address"), [])
    }

    func testPlugNamesMatchWithoutCaseOrSpaces() {
        XCTAssertTrue(KasaSearch.matches("Garland", "garland "))
        XCTAssertTrue(KasaSearch.matches("Window lights", "window Lights"))
        XCTAssertFalse(KasaSearch.matches("Garland", "Garland 2"))
    }

    func testKasaCommandsAndAnswer() {
        XCTAssertEqual(KasaPlug.relay(true) as NSDictionary, ["system": ["set_relay_state": ["state": 1]]] as NSDictionary)
        XCTAssertEqual(KasaPlug.relay(false) as NSDictionary, ["system": ["set_relay_state": ["state": 0]]] as NSDictionary)
        let answer: [String: Any] = ["system": ["get_sysinfo": ["alias": "Garland", "relay_state": 1]]]
        XCTAssertEqual(KasaPlug.sysinfo(in: answer)?["alias"] as? String, "Garland")
        XCTAssertNil(KasaPlug.sysinfo(in: ["system": ["err_code": -1]]))
        XCTAssertNil(KasaPlug.sysinfo(in: [:]))
    }

    func testResultStoreKeepsTheLastGoodValue() {
        var value: Int?
        var error: Error?
        Result<Int, Error>.success(3).store(in: &value, error: &error)
        XCTAssertEqual(value, 3)
        XCTAssertNil(error)
        Result<Int, Error>.failure(ServiceError.badResponse).store(in: &value, error: &error)
        XCTAssertEqual(value, 3, "a failed fetch keeps the old data")
        XCTAssertNotNil(error)
        Result<Int, Error>.success(4).store(in: &value, error: &error)
        XCTAssertEqual(value, 4)
        XCTAssertNil(error, "a success clears the error")
    }

    func testQueryEncodesPlus() {
        let built = url(URL(string: "https://example.com/api")!, query: ["tz": "+01:00", "a": "x y"])
        XCTAssertEqual(built.absoluteString, "https://example.com/api?a=x%20y&tz=%2B01:00")
    }

    func testVersionComparison() {
        XCTAssertEqual(VersionCheck.version(fromTag: "v2026.11.10.11"), "2026.11.10.11")
        XCTAssertEqual(VersionCheck.version(fromTag: "2026.11.10.11"), "2026.11.10.11")
        XCTAssertTrue(VersionCheck.isNewer("2026.11.10.11", than: "2026.11.10.9"), "11 > 9, not as text")
        XCTAssertTrue(VersionCheck.isNewer("2026.11.11.1", than: "2026.11.10.11"))
        XCTAssertTrue(VersionCheck.isNewer("2026.12.1.1", than: "2026.11.30.4"))
        XCTAssertFalse(VersionCheck.isNewer("2026.11.10.11", than: "2026.11.10.11"))
        XCTAssertFalse(VersionCheck.isNewer("2026.11.10.10", than: "2026.11.10.11"))
        XCTAssertFalse(VersionCheck.isNewer("2026.11.10.11", than: "dev"), "a dev build is never out of date")
        XCTAssertFalse(VersionCheck.isNewer("nonsense", than: "2026.11.10.11"))
    }

    func testTimeoutsAndDropsAreRecognized() {
        XCTAssertTrue(isTimeout(URLError(.timedOut)))
        XCTAssertFalse(isTimeout(URLError(.networkConnectionLost)))
        XCTAssertFalse(isTimeout(ServiceError.badResponse))
        XCTAssertTrue(isDroppedConnection(URLError(.networkConnectionLost)))
        XCTAssertFalse(isDroppedConnection(URLError(.timedOut)))
    }

    func testOfflineErrorsAreMarked() {
        XCTAssertTrue(PageAlert("GitHub", error: URLError(.notConnectedToInternet)).offline)
        XCTAssertTrue(PageAlert("GitHub", error: URLError(.timedOut)).offline)
        XCTAssertTrue(PageAlert("GitHub", error: ServiceError.noResponse("connection dropped")).offline)
        XCTAssertEqual(PageAlert("GitHub", error: ServiceError.noResponse("connection dropped")).detail, "connection dropped")
        XCTAssertFalse(PageAlert("GitHub", error: ServiceError.http(500, nil)).offline)
        XCTAssertEqual(PageAlert("GitHub", error: ServiceError.http(500, "boom")).detail, "HTTP 500: boom")
    }

    func testGitHubOpenPRAlerts() {
        let now = Date()
        func pr(_ repo: String, hours: Double) -> OpenPR {
            return OpenPR(repo: repo, number: 1, title: "t", created: now.addingTimeInterval(-hours * 3600))
        }
        var s = GitHubSnapshot()
        XCTAssertEqual(s.alerts(now: now), [])
        XCTAssertEqual(s.headline(now: now), "0 open pull requests")

        // Four young PRs: no alert. Five: one, and the headline says so.
        s.openPRs = (0..<4).map { _ in pr("art", hours: 2) }
        s.openCount = 4
        XCTAssertEqual(s.alerts(now: now), [])
        XCTAssertEqual(s.headline(now: now), "4 open pull requests")
        s.openPRs.append(pr("cams", hours: 3))
        s.openCount = 5
        XCTAssertEqual(s.alerts(now: now), [PageAlert("5 PRs older than 15 minutes")])
        XCTAssertEqual(s.headline(now: now), "5 PRs older than 15 minutes")

        // One PR older than a day is an alert on its own, naming its repository.
        s.openPRs = [pr("art", hours: 49)]
        s.openCount = 1
        XCTAssertEqual(s.alerts(now: now), [PageAlert("1 PR older than 24 hours", "art, 2 days")])
        XCTAssertEqual(s.headline(now: now), "1 PR older than 24 hours")

        // Both: the overdue ones first, on the summary and in the headline.
        s.openPRs = [pr("art", hours: 75), pr("cams", hours: 30)] + (0..<4).map { _ in pr("x", hours: 1) }
        s.openCount = 6
        XCTAssertEqual(s.alerts(now: now), [PageAlert("2 PRs older than 24 hours", "oldest 3 days"),
                                            PageAlert("6 PRs older than 15 minutes")])
        XCTAssertEqual(s.headline(now: now), "2 PRs older than 24 hours")
        XCTAssertEqual(s.overdue(now: now).map { $0.repo }, ["art", "cams"])
    }

    func testGitHubDemoPRsAreOldestFirst() {
        let s = GitHubPageViewController.demo(open: 8, into: GitHubSnapshot())
        XCTAssertEqual(s.openCount, 8)
        XCTAssertEqual(s.openPRs.count, 8)
        XCTAssertEqual(s.openPRs.map { $0.created }, s.openPRs.map { $0.created }.sorted())
    }
}
