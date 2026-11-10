import CoreLocation
import Foundation

// Hourly temperatures for where the iPad is, from Open-Meteo (free, no key).
// The location comes from Location Services (Wi-Fi positioning is plenty) and is
// remembered, so a fetch still works when a fresh fix isn't available.

struct HourlyTemperature {
    let time: Date
    let celsius: Double
}

struct WeatherForecast {
    var hours: [HourlyTemperature] = []
}

final class WeatherService: NSObject, CLLocationManagerDelegate {
    private let hours = SummaryPageViewController.hours + 3
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var waiting: [(CLLocation?) -> Void] = []
    /// The town's name, once the lookup after the first fix has answered.
    private(set) var place: String?
    /// How long to wait for an answer to the location permission prompt.
    private let promptTimeout: TimeInterval = 20
    private static let latKey = "weatherLatitude", lonKey = "weatherLongitude", fixKey = "weatherLocationTime"
    /// A wall dashboard doesn't move: a fix this recent is used without asking for a new one.
    private let fixGoodFor: TimeInterval = 24 * 3600

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Completes on the main queue.
    func fetchForecast(completion: @escaping (Result<WeatherForecast, Error>) -> Void) {
        locate { location in
            guard let location = location else {
                return completion(.failure(ServiceError.api(self.locationProblem)))
            }
            self.lookUpPlace(location)
            let c = location.coordinate
            let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(c.latitude)&longitude=\(c.longitude)"
                + "&hourly=temperature_2m&forecast_hours=\(self.hours)&timeformat=unixtime&timezone=auto")!
            fetchJSON(URLRequest(url: url), errorKey: "reason") { result in
                completion(result.flatMap { json in
                    guard let hourly = json["hourly"] as? [String: Any],
                          let times = hourly["time"] as? [NSNumber],
                          let temps = hourly["temperature_2m"] as? [Any] else {
                        return .failure(ServiceError.badResponse)
                    }
                    let hours = zip(times, temps).compactMap { time, temp -> HourlyTemperature? in
                        guard let celsius = (temp as? NSNumber)?.doubleValue else { return nil }
                        return HourlyTemperature(time: Date(timeIntervalSince1970: time.doubleValue), celsius: celsius)
                    }
                    return .success(WeatherForecast(hours: hours))
                })
            }
        }
    }

    // MARK: - Location

    private var savedLocation: CLLocation? {
        get {
            let d = UserDefaults.standard
            guard d.object(forKey: WeatherService.latKey) != nil else { return nil }
            return CLLocation(latitude: d.double(forKey: WeatherService.latKey),
                              longitude: d.double(forKey: WeatherService.lonKey))
        }
        set {
            UserDefaults.standard.set(newValue?.coordinate.latitude, forKey: WeatherService.latKey)
            UserDefaults.standard.set(newValue?.coordinate.longitude, forKey: WeatherService.lonKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: WeatherService.fixKey)
        }
    }

    private var locationProblem: String {
        switch CLLocationManager.authorizationStatus() {
        case .denied, .restricted: return "location access is off"
        default: return CLLocationManager.locationServicesEnabled() ? "location unknown" : "Location Services are off"
        }
    }

    /// The last fix while it is recent; else a fresh one if it comes, otherwise the last one known.
    private func locate(_ completion: @escaping (CLLocation?) -> Void) {
        switch CLLocationManager.authorizationStatus() {
        case .notDetermined:
            waiting.append(completion)
            manager.requestWhenInUseAuthorization()
            // Nobody may be there to answer the prompt: don't hold the fetch for it.
            DispatchQueue.main.asyncAfter(deadline: .now() + promptTimeout) {
                if CLLocationManager.authorizationStatus() == .notDetermined { self.finish(self.savedLocation) }
            }
        case .authorizedWhenInUse, .authorizedAlways:
            let fixAge = Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: WeatherService.fixKey)
            if let saved = savedLocation, fixAge < fixGoodFor { return completion(saved) }
            waiting.append(completion)
            if waiting.count == 1 { manager.requestLocation() }
        default:
            completion(savedLocation)
        }
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        guard !waiting.isEmpty, status != .notDetermined else { return }
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.requestLocation()
        } else {
            finish(savedLocation)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.last { savedLocation = location }
        finish(savedLocation)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(savedLocation)
    }

    private func finish(_ location: CLLocation?) {
        let callbacks = waiting
        waiting = []
        DispatchQueue.main.async { callbacks.forEach { $0(location) } }
    }

    /// The town's name for the heading, looked up once; the page reads `place`.
    private func lookUpPlace(_ location: CLLocation) {
        guard place == nil, !geocoder.isGeocoding else { return }
        geocoder.reverseGeocodeLocation(location) { placemarks, _ in
            self.place = placemarks?.first?.locality
        }
    }
}
