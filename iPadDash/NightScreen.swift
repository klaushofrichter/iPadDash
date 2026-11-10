import UIKit

/// From 10 PM to 5 AM: only a dim clock on black, at the screen's lowest brightness,
/// in a window of its own above everything (Settings included). A tap brings the
/// dashboard back for 15 minutes. The pages keep updating underneath and the
/// charging plug keeps working; the camera doesn't sample meanwhile.
final class NightScreen {
    static let shared = NightScreen()

    static let startHour = 22
    static let endHour = 5
    private let wakeDuration: TimeInterval = 15 * 60

    private(set) var isActive = false
    private var awakeUntil: Date?
    private var window: UIWindow?
    private let clock = UILabel()
    private var timer: Timer?
    /// The brightness before the night, given back in the morning.
    private var dayBrightness: CGFloat?

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.update() }
        update()
    }

    var isNight: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("night") { return true }
        #endif
        let hour = Calendar.current.component(.hour, from: Date())
        return hour >= NightScreen.startHour || hour < NightScreen.endHour
    }

    private func update() {
        if let until = awakeUntil, Date() >= until { awakeUntil = nil }
        let shouldShow = isNight && awakeUntil == nil
        if shouldShow != isActive { shouldShow ? show() : hide() }
        clock.text = timeOfDayFormatter.string(from: Date())
    }

    private func show() {
        isActive = true
        dayBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = 0
        let window = self.window ?? makeWindow()
        window.alpha = 0
        window.isHidden = false
        UIView.animate(withDuration: 1.5) { window.alpha = 1 }
    }

    private func hide() {
        isActive = false
        // Back to the brightness before the night first: the camera sample that
        // follows can fail, and must not leave the screen dark all day.
        if let brightness = dayBrightness { UIScreen.main.brightness = brightness }
        if AmbientLight.shared.isOn { AmbientLight.shared.start() }   // samples the room again
        guard let window = window else { return }
        UIView.animate(withDuration: 1.5, animations: { window.alpha = 0 }) { _ in
            if !self.isActive { window.isHidden = true }
        }
    }

    @objc private func tapped() {
        awakeUntil = Date().addingTimeInterval(wakeDuration)
        update()
    }

    private func makeWindow() -> UIWindow {
        let window = UIWindow(frame: UIScreen.main.bounds)
        if #available(iOS 13.0, *) {   // simulators: a window needs the scene to show
            window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        }
        window.windowLevel = UIWindow.Level.alert + 1
        let controller = NightViewController()
        controller.view.backgroundColor = .black
        clock.font = UIFont.monospacedDigitSystemFont(ofSize: 64, weight: .thin)
        clock.textColor = UIColor(white: 0.3, alpha: 1)
        clock.textAlignment = .center
        clock.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(clock)
        NSLayoutConstraint.activate([
            clock.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            clock.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
        ])
        controller.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        window.rootViewController = controller
        self.window = window
        return window
    }
}

private final class NightViewController: UIViewController {
    override var prefersStatusBarHidden: Bool { return true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { return .portrait }
}
