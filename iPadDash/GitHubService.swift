import Foundation

// Pull request activity across the repositories owned by klaushofrichter, via
// GitHub's search API and a fine-grained token (Pull requests: read-only on all
// repositories). Each refresh is three searches: open PRs (at least 15 minutes old), merged in the last
// 24 h (count only), and merged in the last 30 days (count and the newest ones,
// via GraphQL for their target branch).

struct MergedPR {
    let repo: String
    let number: Int
    let title: String
    let mergedAt: Date
    let base: String            // target branch, e.g. "main" or "production"
}

/// Open PRs younger than this are taken to be work in progress and left out.
private let openPRMinAge: TimeInterval = 15 * 60

struct GitHubSnapshot {
    var openCount = 0
    var openByRepo: [(repo: String, count: Int, oldest: Date?)] = []   // most open PRs first
    var merged24h = 0
    var merged30d = 0
    var recentMerges: [MergedPR] = []                   // newest first
}

enum GitHubError: LocalizedError {
    case missingToken
    case http(Int, String?)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingToken: return "no GitHub token in Secrets.plist"
        case .http(let code, let message): return message.map { "HTTP \(code): \($0)" } ?? "HTTP \(code)"
        case .badResponse: return "unexpected response"
        }
    }
}

final class GitHubService {
    let owner = "klaushofrichter"
    private let token: String?
    private let session: URLSession

    init() {
        var token: String?
        if let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
           let dict = NSDictionary(contentsOf: url),
           let value = dict["GitHubToken"] as? String, !value.isEmpty {
            token = value
        }
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    var hasToken: Bool { return token != nil }

    /// Completes on the main queue; fails if any of the searches fails.
    func fetchSnapshot(completion: @escaping (Result<GitHubSnapshot, Error>) -> Void) {
        guard token != nil else { return completion(.failure(GitHubError.missingToken)) }
        let now = Date()
        var snapshot = GitHubSnapshot()
        var firstError: Error?
        let group = DispatchGroup()

        func search(_ query: String, perPage: Int, sort: String? = nil,
                    _ apply: @escaping (Int, [[String: Any]]) -> Void) {
            group.enter()
            self.search(query, perPage: perPage, sort: sort) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let (total, items)): apply(total, items)
                    case .failure(let error): firstError = firstError ?? error
                    }
                    group.leave()
                }
            }
        }

        search("is:pr is:open archived:false user:\(owner) created:<=\(isoDateTime(now.addingTimeInterval(-openPRMinAge)))",
               perPage: 100) { total, items in
            snapshot.openCount = total
            var counts: [String: Int] = [:]
            var oldest: [String: Date] = [:]
            for item in items {
                let repo = GitHubService.repoName(item)
                counts[repo, default: 0] += 1
                if let created = (item["created_at"] as? String).flatMap(parseISODate) {
                    oldest[repo] = min(oldest[repo] ?? created, created)
                }
            }
            snapshot.openByRepo = counts.map { (repo: $0.key, count: $0.value, oldest: oldest[$0.key]) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.repo < $1.repo }
        }
        search("is:pr is:merged user:\(owner) merged:>=\(isoDateTime(now.addingTimeInterval(-86400)))",
               perPage: 1) { total, _ in
            snapshot.merged24h = total
        }
        // GraphQL rather than REST search, so each merge comes with its target branch.
        // Sorted by last update, which for merged PRs is (nearly always) the merge;
        // re-sorted by merge time below.
        group.enter()
        let query = "is:pr is:merged user:\(owner) merged:>=\(isoDateTime(now.addingTimeInterval(-30 * 86400))) sort:updated-desc"
        graphQLSearch(query, first: 50) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let (total, nodes)):
                    snapshot.merged30d = total
                    snapshot.recentMerges = nodes.compactMap { node -> MergedPR? in
                        guard let merged = (node["mergedAt"] as? String).flatMap(parseISODate),
                              let number = (node["number"] as? NSNumber)?.intValue else { return nil }
                        let repo = (node["repository"] as? [String: Any])?["name"] as? String ?? "?"
                        return MergedPR(repo: repo, number: number, title: node["title"] as? String ?? "",
                                        mergedAt: merged, base: node["baseRefName"] as? String ?? "?")
                    }.sorted { $0.mergedAt > $1.mergedAt }
                case .failure(let error): firstError = firstError ?? error
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            if let error = firstError {
                completion(.failure(error))
            } else {
                completion(.success(snapshot))
            }
        }
    }

    private static func repoName(_ item: [String: Any]) -> String {
        return (item["repository_url"] as? String)?.components(separatedBy: "/").last ?? "?"
    }

    private func graphQLSearch(_ query: String, first: Int,
                               completion: @escaping (Result<(Int, [[String: Any]]), Error>) -> Void) {
        let gql = """
            query($q: String!, $n: Int!) { search(query: $q, type: ISSUE, first: $n) { issueCount
              nodes { ... on PullRequest { number title mergedAt baseRefName repository { name } } } } }
            """
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "query": gql, "variables": ["q": query, "n": first]])
        session.trackedDataTask(with: request) { data, response, error in
            if let error = error { return completion(.failure(error)) }
            let json = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return completion(.failure(GitHubError.http(http.statusCode, json?["message"] as? String)))
            }
            if let message = (json?["errors"] as? [[String: Any]])?.first?["message"] as? String {
                return completion(.failure(GitHubError.http(200, message)))
            }
            guard let search = (json?["data"] as? [String: Any])?["search"] as? [String: Any],
                  let total = (search["issueCount"] as? NSNumber)?.intValue else {
                return completion(.failure(GitHubError.badResponse))
            }
            completion(.success((total, search["nodes"] as? [[String: Any]] ?? [])))
        }.resume()
    }

    private func search(_ query: String, perPage: Int, sort: String?,
                        completion: @escaping (Result<(Int, [[String: Any]]), Error>) -> Void) {
        var components = URLComponents(string: "https://api.github.com/search/issues")!
        var items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "per_page", value: String(perPage))]
        if let sort = sort {
            items += [URLQueryItem(name: "sort", value: sort), URLQueryItem(name: "order", value: "desc")]
        }
        components.queryItems = items
        // "+" in the ISO time zone would otherwise read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        session.trackedDataTask(with: request) { data, response, error in
            if let error = error { return completion(.failure(error)) }
            let json = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return completion(.failure(GitHubError.http(http.statusCode, json?["message"] as? String)))
            }
            guard let body = json, let total = (body["total_count"] as? NSNumber)?.intValue else {
                return completion(.failure(GitHubError.badResponse))
            }
            completion(.success((total, body["items"] as? [[String: Any]] ?? [])))
        }.resume()
    }
}

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private func isoDateTime(_ date: Date) -> String { return isoFormatter.string(from: date) }
private func parseISODate(_ text: String) -> Date? { return isoFormatter.date(from: text) }
