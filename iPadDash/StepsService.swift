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

final class StepsService {
    private let baseURL = URL(string: "https://steps.skylar.technology")!
    private let token = Secrets.string("StepsToken")

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
            completion(.failure(ServiceError.missing("token")))
            return
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        fetchJSON(request, errorKey: "error") { result in
            switch result {
            case .success(let json):
                if let value = decode(json) {
                    completion(.success(value))
                } else {
                    completion(.failure(ServiceError.badResponse))
                }
            // The service keeps its data in memory: after a restart it answers 404
            // ("no steps data has been submitted yet") until the next reading arrives.
            case .failure(ServiceError.http(404, _)):
                completion(.failure(ServiceError.api("no data yet")))
            case .failure(ServiceError.http(_, let message?)):
                completion(.failure(ServiceError.api(message)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
}

/// ISO 8601, with or without fractional seconds; "n/a" and anything else -> nil.
func parseDate(_ value: Any?) -> Date? {
    guard let string = value as? String else { return nil }
    return isoFractional.date(from: string) ?? isoPlain.date(from: string)
}

private let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

let isoPlain = ISO8601DateFormatter()
