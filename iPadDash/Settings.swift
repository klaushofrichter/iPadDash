import UIKit

/// App-level light/dark theme; iOS 12 has no system dark mode.
enum Theme {
    static let didChange = Notification.Name("ThemeDidChange")
    private static let key = "darkMode"

    /// Kept in memory: every drawn color reads it.
    static var isDark = UserDefaults.standard.bool(forKey: key) {
        didSet {
            UserDefaults.standard.set(isDark, forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}

/// User settings shown on the Settings page.
enum Settings {
    static let didChange = Notification.Name("SettingsDidChange")

    /// Choices for the background update interval, in seconds. steps-service allows
    /// 40 requests per 5 minutes per token (shared with TRMNL), and each update
    /// costs one request per endpoint, so 30 s is the practical minimum.
    static let refreshIntervals: [TimeInterval] = [30, 60, 120, 300, 900]
    private static let intervalKey = "refreshInterval"

    static var refreshInterval: TimeInterval {
        get { return stored(intervalKey, in: refreshIntervals, default: 60) }
        set {
            save(newValue, intervalKey)
        }
    }

    private static func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    private static func stored<T: Equatable>(_ key: String, in choices: [T], default fallback: T) -> T {
        guard let value = UserDefaults.standard.object(forKey: key) as? T, choices.contains(value) else {
            return fallback
        }
        return value
    }

    /// Choices for the date and time in the page footer; the first is the default.
    static let clockFormatters: [DateFormatter] = [
        clockFormatter("EEE MMM d, h:mm a", am: "AM", pm: "PM"),
        clockFormatter("yyyy-MM-dd hh:mm:ss a", am: "am", pm: "pm"),
    ]
    private static let clockFormatKey = "clockFormat"

    static var clockFormat: Int {
        get { return stored(clockFormatKey, in: Array(clockFormatters.indices), default: 0) }
        set {
            save(newValue, clockFormatKey)
        }
    }

    private static func clockFormatter(_ format: String, am: String, pm: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        f.amSymbol = am
        f.pmSymbol = pm
        f.shortWeekdaySymbols = f.shortWeekdaySymbols.map { $0.uppercased() }   // TUE
        return f
    }

    /// Automatic page advance ("auto-move"), in seconds; 0 means none.
    static let autoMoveIntervals: [TimeInterval] = [0, 15, 30, 60]
    private static let autoMoveKey = "autoMoveInterval"

    static var autoMoveInterval: TimeInterval {
        get { return stored(autoMoveKey, in: autoMoveIntervals, default: 15) }
        set {
            save(newValue, autoMoveKey)
        }
    }

    /// With the summary page on, how long another page stays before going back to
    /// it; twice that for a page swiped to.
    static var summaryReturnInterval: TimeInterval {
        return autoMoveInterval > 0 ? autoMoveInterval : 15
    }

    /// The summary page is the home page: shown alone, and returned to after a swipe.
    /// Off, it isn't shown at all.
    private static let summaryKey = "summaryPage"

    static var summaryPage: Bool {
        get { return UserDefaults.standard.bool(forKey: summaryKey) }
        set {
            save(newValue, summaryKey)
        }
    }

    /// The Kasa plug the charger is plugged into: its name in the Kasa app ("Garland"),
    /// which the app looks up on the network, or its IP address; empty = no charge control.
    private static let chargePlugKey = "chargePlug"

    static var chargePlug: String {
        get { return UserDefaults.standard.string(forKey: chargePlugKey) ?? "" }
        set {
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value != chargePlug else { return }
            save(value, chargePlugKey)
        }
    }

    /// Saves settings given as launch arguments, "chargePlug=Garland", as if
    /// entered on the Settings page, so deploy.sh can set them without touching the iPad.
    static func applyLaunchArguments() {
        for argument in ProcessInfo.processInfo.arguments.dropFirst() {
            let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case chargePlugKey: chargePlug = parts[1]
            default: NSLog("iPadDash: unknown setting %@", parts[0])
            }
        }
    }

    /// How often the front camera samples room brightness, in seconds; 0 means off.
    static let ambientIntervals: [TimeInterval] = [0, 60, 300, 900]
    private static let ambientKey = "ambientInterval"

    static var ambientInterval: TimeInterval {
        get { return stored(ambientKey, in: ambientIntervals, default: 300) }
        set { UserDefaults.standard.set(newValue, forKey: ambientKey) }
    }
}

func intervalText(_ seconds: TimeInterval) -> String {
    return seconds < 60 ? "\(Int(seconds)) s" : "\(Int(seconds / 60)) min"
}
