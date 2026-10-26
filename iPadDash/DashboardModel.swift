import Foundation

// Pace math ported from trmnl-steps-plugin.liquid so the iPad shows the same
// verdicts as the TRMNL device. Keep the two in sync.

let stepsGoal = 10_000
private let stepsWindowStartMin = 6 * 60   // 06:00 local
private let stepsWindowEndMin = 21 * 60    // 21:00 local
private let onPaceTolerance = 2.0          // percentage points either way

/// Liquid's `round` on a float: half away from zero.
private func liquidRound(_ x: Double) -> Int { return Int(x.rounded()) }

struct StepsSummary {
    let steps: Int
    let pacePct: Int          // outer ring
    let actualPct: Int        // inner ring (uncapped; the view caps at 100)
    let status: String
    let hero: String          // "2,800 to go" / "1,200 above"
    let freshness: String

    init(reading: StepsReading, now: Date, calendar: Calendar = .current) {
        steps = reading.steps
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let nowMin = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let windowLen = stepsWindowEndMin - stepsWindowStartMin
        let elapsed = min(max(nowMin - stepsWindowStartMin, 0), windowLen)
        pacePct = liquidRound(Double(elapsed) * 100 / Double(windowLen))
        actualPct = liquidRound(Double(steps) * 100 / Double(stepsGoal))

        let delta = actualPct - pacePct
        if Double(delta) > onPaceTolerance {
            status = "Ahead of pace"
        } else if Double(delta) < -onPaceTolerance {
            status = "Behind pace"
        } else {
            status = "On pace"
        }

        let remaining = max(stepsGoal - steps, 0)
        let raw = remaining > 0 ? remaining : steps - stepsGoal
        let rounded = (raw + 99) / 100 * 100   // round up to the nearest 100
        hero = "\(groupedNumber(rounded)) \(remaining > 0 ? "to go" : "above")"
        freshness = freshnessText(since: reading.timestamp, now: now)
    }
}

struct UsageWindow {
    let name: String
    let actual: Double?       // nil when the service reports "n/a"
    let pace: Int             // 0...100; 0 when unknown, 100 when expired
    let delta: Double
    let expired: Bool
    let status: String        // "Overuse" / "Underuse" / "On pace" / "Expired" / "n/a"

    var available: Bool { return actual != nil && status != "n/a" }

    init(name: String, actual: Double?, reset: Date?, windowHours: Double, now: Date) {
        self.name = name
        self.actual = actual
        guard let actual = actual, let reset = reset else {
            pace = 0; delta = 0; expired = false; status = "n/a"
            return
        }
        let remainingHours = reset.timeIntervalSince(now) / 3600
        let rawPace = max(liquidRound((windowHours - remainingHours) * 100 / windowHours), 0)
        // pace == 100 is the reset instant and still a live window; only > 100 means it ended.
        if rawPace > 100 {
            pace = 100; delta = 0; expired = true; status = "Expired"
        } else {
            pace = rawPace
            delta = actual - Double(rawPace)
            expired = false
            if delta > onPaceTolerance {
                status = "Overuse"
            } else if delta < -onPaceTolerance {
                status = "Underuse"
            } else {
                status = "On pace"
            }
        }
    }

    var caption: String {
        let actualText = actual.map(percentText) ?? "n/a"
        return expired ? "window ended / actual \(actualText)%" : "pace \(pace)% / actual \(actualText)%"
    }
}

struct ClaudeSummary {
    let weekly: UsageWindow
    let session: UsageWindow
    let hero: String
    let freshness: String

    init(reading: ClaudeReading, now: Date) {
        weekly = UsageWindow(name: "Weekly", actual: reading.weekly, reset: reading.weeklyReset,
                             windowHours: 168, now: now)
        session = UsageWindow(name: "Session", actual: reading.session, reset: reading.sessionReset,
                              windowHours: 5, now: now)
        if !weekly.available {
            hero = "n/a"
        } else if weekly.expired {
            hero = "\(percentText(weekly.actual ?? 0))% used"
        } else {
            hero = "\(percentText(abs(weekly.delta)))% \(weekly.delta < 0 ? "Underuse" : "Overuse")"
        }
        freshness = freshnessText(since: reading.timestamp, now: now)
    }
}

/// "updated just now" / "updated 12 min ago" / "updated 3 hours ago" / "DATA IS OUTDATED"
func freshnessText(since timestamp: Date, now: Date) -> String {
    let ageSec = max(Int(now.timeIntervalSince(timestamp)), 0)
    let ageMin = ageSec / 60
    let ageHr = ageSec / 3600
    if ageSec >= 6 * 3600 { return "DATA IS OUTDATED" }
    if ageMin < 5 { return "updated just now" }
    if ageHr < 1 { return "updated \(ageMin) min ago" }
    if ageHr == 1 { return "updated 1 hour ago" }
    return "updated \(ageHr) hours ago"
}

func groupedNumber(_ n: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = Locale(identifier: "en_US")
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}

/// Whole numbers without decimals, like Liquid prints them; otherwise one decimal.
func percentText(_ value: Double) -> String {
    return value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
}
