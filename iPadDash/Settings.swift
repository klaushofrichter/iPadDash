import UIKit

/// App-level light/dark theme; iOS 12 has no system dark mode.
enum Theme {
    static let didChange = Notification.Name("ThemeDidChange")
    private static let key = "darkMode"

    static var isDark: Bool {
        get { return UserDefaults.standard.bool(forKey: key) }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}

/// User settings shown on the About page.
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
            UserDefaults.standard.set(newValue, forKey: intervalKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
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
            UserDefaults.standard.set(newValue, forKey: clockFormatKey)
            NotificationCenter.default.post(name: didChange, object: nil)
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
            UserDefaults.standard.set(newValue, forKey: autoMoveKey)
            NotificationCenter.default.post(name: didChange, object: nil)
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
