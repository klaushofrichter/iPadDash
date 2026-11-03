import Foundation

// UptimeRobot monitors (the same data as the public status page
// https://stats.uptimerobot.com/8tOmmY5B64), read with a read-only API key.
// One getMonitors call returns status, 30-day uptime, one uptime value per
// day for the last 30 days, and the latest down/up events.

struct UptimeMonitor {
    enum Status { case up, down, paused, pending }

    let name: String
    let url: String
    let status: Status
    let uptime30: Double?
    let daily: [Double?]          // oldest first; nil = no data that day
    let downSince: Date?          // start of the current outage, if down
}

enum UptimeError: LocalizedError {
    case missingKey
    case http(Int)
    case api(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: return "no UptimeRobot key in Secrets.plist"
        case .http(let code): return "HTTP \(code)"
        case .api(let message): return message
        case .badResponse: return "unexpected response"
        }
    }
}

final class UptimeService {
    static let days = 30
    private let apiKey: String?
    private let session: URLSession

    init() {
        var key: String?
        if let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
           let dict = NSDictionary(contentsOf: url),
           let value = dict["UptimeRobotKey"] as? String, !value.isEmpty {
            key = value
        }
        apiKey = key
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    var hasKey: Bool { return apiKey != nil }

    /// Completes on the main queue.
    func fetchMonitors(completion: @escaping (Result<[UptimeMonitor], Error>) -> Void) {
        guard let apiKey = apiKey else { return completion(.failure(UptimeError.missingKey)) }

        // Day ranges in local time, oldest first; today ends now.
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let ranges = (0..<UptimeService.days).reversed().map { back -> String in
            let start = calendar.date(byAdding: .day, value: -back, to: today)!
            let end = min(calendar.date(byAdding: .day, value: 1, to: start)!, now)
            return "\(Int(start.timeIntervalSince1970))_\(Int(end.timeIntervalSince1970))"
        }

        var request = URLRequest(url: URL(string: "https://api.uptimerobot.com/v2/getMonitors")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = ["api_key": apiKey, "format": "json", "custom_uptime_ratios": "30",
                    "custom_uptime_ranges": ranges.joined(separator: "-"), "logs": "1", "logs_limit": "1"]
        request.httpBody = form.map { "\($0.key)=\($0.value)" }.joined(separator: "&").data(using: .utf8)

        session.trackedDataTask(with: request) { data, response, error in
            let result: Result<[UptimeMonitor], Error>
            if let error = error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(UptimeError.http(http.statusCode))
            } else if let data = data,
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if json["stat"] as? String == "ok", let monitors = json["monitors"] as? [[String: Any]] {
                    result = .success(monitors.map(UptimeService.parse))
                } else {
                    let message = (json["error"] as? [String: Any])?["message"] as? String
                    result = .failure(UptimeError.api(message ?? "API error"))
                }
            } else {
                result = .failure(UptimeError.badResponse)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private static func parse(_ m: [String: Any]) -> UptimeMonitor {
        let code = (m["status"] as? NSNumber)?.intValue ?? 1
        let status: UptimeMonitor.Status
        switch code {
        case 0: status = .paused
        case 2: status = .up
        case 8, 9: status = .down
        default: status = .pending
        }
        // The latest log entry of type 1 ("down") marks when the current outage began.
        var downSince: Date?
        if status == .down, let log = (m["logs"] as? [[String: Any]])?.first,
           (log["type"] as? NSNumber)?.intValue == 1, let t = (log["datetime"] as? NSNumber)?.doubleValue {
            downSince = Date(timeIntervalSince1970: t)
        }
        let daily = ((m["custom_uptime_ranges"] as? String) ?? "")
            .split(separator: "-").map { Double($0) }
        return UptimeMonitor(name: m["friendly_name"] as? String ?? "?",
                             url: m["url"] as? String ?? "",
                             status: status,
                             uptime30: (m["custom_uptime_ratio"] as? String).flatMap(Double.init),
                             daily: daily,
                             downSince: downSince)
    }
}
