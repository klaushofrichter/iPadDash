import Foundation

// Client for steps-service (https://github.com/klaushofrichter/steps-service),
// the same backend the TRMNL plugin in klaushofrichter/trmnl-for-steps polls.
//   GET /steps  -> {timestamp, steps}
//   GET /claude -> {timestamp, session, weekly, sessionReset, weeklyReset}
// Percentages and reset times may be the literal string "n/a".

struct StepsReading {
    let timestamp: Date
    let steps: Int
}

struct ClaudeReading {
    let timestamp: Date
    let session: Double?
    let weekly: Double?
    let sessionReset: Date?
    let weeklyReset: Date?
}

enum StepsServiceError: LocalizedError {
    case missingToken
    case http(Int, String?)     // status and the service's {"error": ...} message
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingToken: return "no token in Secrets.plist"
        // The service keeps its data in memory: after a restart it answers 404
        // ("no steps data has been submitted yet") until the next reading arrives.
        case .http(404, _): return "no data yet"
        case .http(let code, let message): return message ?? "HTTP \(code)"
        case .badResponse: return "unexpected response"
        }
    }
}

final class StepsService {
    private let baseURL: URL
    private let token: String?
    private let session: URLSession

    init(baseURL: URL = URL(string: "https://steps.skylar.technology")!,
         token: String? = StepsService.tokenFromBundle()) {
        self.baseURL = baseURL
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    /// The bearer token lives in iPadDash/Secrets.plist (git-ignored), key "StepsToken".
    static func tokenFromBundle() -> String? {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url),
              let token = dict["StepsToken"] as? String,
              !token.isEmpty, token != "PASTE_TOKEN_HERE" else { return nil }
        return token
    }

    func fetchSteps(completion: @escaping (Result<StepsReading, Error>) -> Void) {
        get("steps", completion: completion) { json in
            guard let ts = parseDate(json["timestamp"]),
                  let steps = json["steps"] as? NSNumber else { return nil }
            return StepsReading(timestamp: ts, steps: steps.intValue)
        }
    }

    func fetchClaude(completion: @escaping (Result<ClaudeReading, Error>) -> Void) {
        get("claude", completion: completion) { json in
            guard let ts = parseDate(json["timestamp"]) else { return nil }
            return ClaudeReading(timestamp: ts,
                                 session: (json["session"] as? NSNumber)?.doubleValue,
                                 weekly: (json["weekly"] as? NSNumber)?.doubleValue,
                                 sessionReset: parseDate(json["sessionReset"]),
                                 weeklyReset: parseDate(json["weeklyReset"]))
        }
    }

    private func get<T>(_ path: String,
                        completion: @escaping (Result<T, Error>) -> Void,
                        decode: @escaping ([String: Any]) -> T?) {
        guard let token = token else {
            completion(.failure(StepsServiceError.missingToken))
            return
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        session.trackedDataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let body = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                completion(.failure(StepsServiceError.http(http.statusCode, body?["error"] as? String)))
                return
            }
            guard let data = data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let value = decode(json) else {
                completion(.failure(StepsServiceError.badResponse))
                return
            }
            completion(.success(value))
        }.resume()
    }
}

/// ISO 8601, with or without fractional seconds; "n/a" and anything else -> nil.
private func parseDate(_ value: Any?) -> Date? {
    guard let string = value as? String else { return nil }
    return isoFractional.date(from: string) ?? isoPlain.date(from: string)
}

private let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let isoPlain = ISO8601DateFormatter()
