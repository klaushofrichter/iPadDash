import Foundation

// Cluster metrics for the k3s cluster "skylar-technology", read from Grafana
// Cloud's hosted Prometheus. Alloy in the cluster already ships these series;
// the app only needs a read-only access policy token (scope metrics:read).
// See docs/cluster-metrics-proposal.md for what is available and why.

/// Thresholds for drawing a value in red.
enum ClusterLimits {
    static let usagePct = 85.0                      // CPU, memory, disk
    static let backupAge: TimeInterval = 26 * 3600  // daily backup plus slack
    static let cronJobAge: TimeInterval = 26 * 3600
    static let certDays = 14.0
    static let sampleAge: TimeInterval = 30 * 60    // Alloy stopped reporting
}

struct ServiceProbe {
    let name: String
    let up: Bool
}

struct CronJobRun {
    let name: String
    let age: TimeInterval
}

/// One refresh worth of cluster data. Fields are nil when a query failed or
/// returned nothing.
struct ClusterSnapshot {
    var cpuPct: Double?
    var memPct: Double?
    var diskPct: Double?
    var load: [Double] = []                 // 1, 5, 15 minutes
    var services: [ServiceProbe] = []
    var backupAge: TimeInterval?
    var certCount = 0
    var certMinDays: Double?
    var certMinName: String?
    var cronJobs: [CronJobRun] = []
    var sampleAge: TimeInterval?
    var cpuHistory: [(Date, Double)] = []
    var memHistory: [(Date, Double)] = []

    var servicesDown: [ServiceProbe] { return services.filter { !$0.up } }
    var stale: Bool { return (sampleAge ?? .infinity) > ClusterLimits.sampleAge }

    /// Anything the cluster page draws in red (same limits as the page).
    var needsAttention: Bool {
        let usage = [cpuPct, memPct, diskPct].compactMap { $0 }.contains { $0 > ClusterLimits.usagePct }
        let backupLate = backupAge.map { $0 > ClusterLimits.backupAge } ?? true
        let certSoon = certMinDays.map { $0 < ClusterLimits.certDays } ?? false
        let cronLate = cronJobs.contains { $0.age > ClusterLimits.cronJobAge }
        return stale || !servicesDown.isEmpty || usage || backupLate || certSoon || cronLate
    }
}

enum GrafanaError: LocalizedError {
    case missingCredentials
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "no Grafana credentials in Secrets.plist"
        case .http(let code): return "HTTP \(code)"
        case .badResponse: return "unexpected response"
        }
    }
}

final class ClusterService {
    private let base = URL(string: "https://prometheus-prod-56-prod-us-east-2.grafana.net/api/prom/api/v1/")!
    private let selector = "cluster=\"skylar-technology\""
    private let auth: String?
    private let session: URLSession

    init() {
        var auth: String?
        if let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
           let dict = NSDictionary(contentsOf: url),
           let user = dict["GrafanaUser"] as? String, !user.isEmpty,
           let token = dict["GrafanaToken"] as? String, !token.isEmpty {
            auth = "Basic " + Data("\(user):\(token)".utf8).base64EncodedString()
        }
        self.auth = auth
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    var hasCredentials: Bool { return auth != nil }

    /// Runs all queries in parallel; completes on the main queue with whatever
    /// succeeded, or with the first error if nothing did.
    func fetchSnapshot(completion: @escaping (Result<ClusterSnapshot, Error>) -> Void) {
        guard auth != nil else {
            completion(.failure(GrafanaError.missingCredentials))
            return
        }
        let c = selector
        var snapshot = ClusterSnapshot()
        var firstError: Error?
        var successes = 0
        let group = DispatchGroup()

        func instant(_ promql: String, _ apply: @escaping ([PromSample]) -> Void) {
            group.enter()
            query(promql) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let samples): apply(samples); successes += 1
                    case .failure(let error): firstError = firstError ?? error
                    }
                    group.leave()
                }
            }
        }

        func range(_ promql: String, _ apply: @escaping ([(Date, Double)]) -> Void) {
            group.enter()
            let end = Date()
            queryRange(promql, start: end.addingTimeInterval(-24 * 3600), end: end, step: 600) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let points): apply(points); successes += 1
                    case .failure(let error): firstError = firstError ?? error
                    }
                    group.leave()
                }
            }
        }

        let cpu = "100 * (1 - avg(rate(node_cpu_seconds_total{\(c),mode=\"idle\"}[5m])))"
        let mem = "100 * (1 - sum(node_memory_MemAvailable_bytes{\(c)}) / sum(node_memory_MemTotal_bytes{\(c)}))"
        instant(cpu) { snapshot.cpuPct = $0.first?.value }
        instant(mem) { snapshot.memPct = $0.first?.value }
        instant("100 * (1 - sum(node_filesystem_avail_bytes{\(c),mountpoint=\"/\"}) / sum(node_filesystem_size_bytes{\(c),mountpoint=\"/\"}))") {
            snapshot.diskPct = $0.first?.value
        }
        instant("{__name__=~\"node_load1|node_load5|node_load15\",\(c)}") { samples in
            let order = ["node_load1", "node_load5", "node_load15"]
            snapshot.load = order.compactMap { name in samples.first { $0.labels["__name__"] == name }?.value }
        }
        instant("app_probe_success{\(c)}") { samples in
            snapshot.services = samples
                .map { ServiceProbe(name: $0.labels["service"] ?? $0.labels["namespace"] ?? "?", up: $0.value >= 1) }
                .sorted { $0.name < $1.name }
        }
        instant("time() - max(velero_backup_last_successful_timestamp{\(c)})") { snapshot.backupAge = $0.first?.value }
        instant("(certmanager_certificate_expiration_timestamp_seconds{\(c)} - time()) / 86400") { samples in
            snapshot.certCount = samples.count
            if let soonest = samples.min(by: { $0.value < $1.value }) {
                snapshot.certMinDays = soonest.value
                snapshot.certMinName = soonest.labels["name"]
            }
        }
        instant("time() - cronjob_last_successful_timestamp_seconds{\(c)}") { samples in
            snapshot.cronJobs = samples
                .map { CronJobRun(name: $0.labels["cronjob"] ?? "?", age: $0.value) }
                .sorted { $0.name < $1.name }
        }
        instant("time() - max(timestamp(up{\(c)}))") { snapshot.sampleAge = $0.first?.value }
        range(cpu) { snapshot.cpuHistory = $0 }
        range(mem) { snapshot.memHistory = $0 }

        group.notify(queue: .main) {
            if successes == 0, let error = firstError {
                completion(.failure(error))
            } else {
                completion(.success(snapshot))
            }
        }
    }

    // MARK: - Prometheus HTTP API

    struct PromSample {
        let labels: [String: String]
        let value: Double
    }

    private func query(_ promql: String, completion: @escaping (Result<[PromSample], Error>) -> Void) {
        get("query", ["query": promql]) { result in
            completion(result.flatMap { data -> Result<[PromSample], Error> in
                guard let series = data["result"] as? [[String: Any]] else { return .failure(GrafanaError.badResponse) }
                return .success(series.compactMap { item in
                    guard let pair = item["value"] as? [Any], pair.count == 2,
                          let text = pair[1] as? String, let value = Double(text), value.isFinite else { return nil }
                    return PromSample(labels: item["metric"] as? [String: String] ?? [:], value: value)
                })
            })
        }
    }

    private func queryRange(_ promql: String, start: Date, end: Date, step: TimeInterval,
                            completion: @escaping (Result<[(Date, Double)], Error>) -> Void) {
        let params = ["query": promql,
                      "start": String(Int(start.timeIntervalSince1970)),
                      "end": String(Int(end.timeIntervalSince1970)),
                      "step": String(Int(step))]
        get("query_range", params) { result in
            completion(result.flatMap { data -> Result<[(Date, Double)], Error> in
                guard let series = data["result"] as? [[String: Any]] else { return .failure(GrafanaError.badResponse) }
                let values = series.first?["values"] as? [[Any]] ?? []
                return .success(values.compactMap { pair in
                    guard pair.count == 2, let t = pair[0] as? Double,
                          let text = pair[1] as? String, let v = Double(text), v.isFinite else { return nil }
                    return (Date(timeIntervalSince1970: t), v)
                })
            })
        }
    }

    private func get(_ endpoint: String, _ params: [String: String],
                     completion: @escaping (Result<[String: Any], Error>) -> Void) {
        var components = URLComponents(url: base.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents leaves "+" alone, but Prometheus would read it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!)
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        session.dataTask(with: request) { data, response, error in
            if let error = error { return completion(.failure(error)) }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return completion(.failure(GrafanaError.http(http.statusCode)))
            }
            guard let data = data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  json["status"] as? String == "success",
                  let payload = json["data"] as? [String: Any] else {
                return completion(.failure(GrafanaError.badResponse))
            }
            completion(.success(payload))
        }.resume()
    }
}

/// "43 min" / "9 h" / "3 d"
func ageText(_ seconds: TimeInterval) -> String {
    if seconds < 3600 { return "\(max(Int(seconds / 60), 0)) min" }
    if seconds < 2 * 86400 { return "\(Int(seconds / 3600)) h" }
    return "\(Int(seconds / 86400)) d"
}
