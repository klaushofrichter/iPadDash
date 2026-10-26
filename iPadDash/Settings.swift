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
        get {
            let stored = UserDefaults.standard.double(forKey: intervalKey)
            return refreshIntervals.contains(stored) ? stored : 60
        }
        set {
            UserDefaults.standard.set(newValue, forKey: intervalKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}

func intervalText(_ seconds: TimeInterval) -> String {
    return seconds < 60 ? "\(Int(seconds)) s" : "\(Int(seconds / 60)) min"
}

/// A swipeable dashboard page.
protocol DashboardPage: AnyObject {
    /// Fetch fresh data for everything on the page now (tap gesture).
    func reloadNow()
}
