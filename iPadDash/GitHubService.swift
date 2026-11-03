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

final class GitHubService {
    let owner = "klaushofrichter"
    private let token = Secrets.string("GitHubToken")

    /// Completes on the main queue; fails if any of the searches fails.
    func fetchSnapshot(completion: @escaping (Result<GitHubSnapshot, Error>) -> Void) {
        guard token != nil else { return completion(.failure(ServiceError.missing("GitHub token"))) }
        let now = Date()
        var snapshot = GitHubSnapshot()
        var firstError: Error?
        let group = DispatchGroup()

        func collect<T>(_ apply: @escaping (T) -> Void) -> (Result<T, Error>) -> Void {
            group.enter()
            return { result in
                switch result {
                case .success(let value): apply(value)
                case .failure(let error): firstError = firstError ?? error
                }
                group.leave()
            }
        }

        func search(_ query: String, perPage: Int, _ apply: @escaping (Int, [[String: Any]]) -> Void) {
            self.search(query, perPage: perPage, completion: collect { apply($0.0, $0.1) })
        }

        search("is:pr is:open archived:false user:\(owner) created:<=\(isoDateTime(now.addingTimeInterval(-openPRMinAge)))",
               perPage: 100) { total, items in
            snapshot.openCount = total
            var counts: [String: Int] = [:]
            var oldest: [String: Date] = [:]
            for item in items {
                let repo = GitHubService.repoName(item)
                counts[repo, default: 0] += 1
                if let created = parseDate(item["created_at"]) {
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
        let query = "is:pr is:merged user:\(owner) merged:>=\(isoDateTime(now.addingTimeInterval(-30 * 86400))) sort:updated-desc"
        graphQLSearch(query, first: 50, completion: collect { (total: Int, nodes: [[String: Any]]) in
            snapshot.merged30d = total
            snapshot.recentMerges = nodes.compactMap { node -> MergedPR? in
                guard let merged = parseDate(node["mergedAt"]),
                      let number = (node["number"] as? NSNumber)?.intValue else { return nil }
                let repo = (node["repository"] as? [String: Any])?["name"] as? String ?? "?"
                return MergedPR(repo: repo, number: number, title: node["title"] as? String ?? "",
                                mergedAt: merged, base: node["baseRefName"] as? String ?? "?")
            }.sorted { $0.mergedAt > $1.mergedAt }
        })

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
        fetchJSON(request, errorKey: "message") { result in
            completion(result.flatMap { json in
                if let message = (json["errors"] as? [[String: Any]])?.first?["message"] as? String {
                    return .failure(ServiceError.http(200, message))
                }
                guard let search = (json["data"] as? [String: Any])?["search"] as? [String: Any],
                      let total = (search["issueCount"] as? NSNumber)?.intValue else {
                    return .failure(ServiceError.badResponse)
                }
                return .success((total, search["nodes"] as? [[String: Any]] ?? []))
            })
        }
    }

    private func search(_ query: String, perPage: Int,
                        completion: @escaping (Result<(Int, [[String: Any]]), Error>) -> Void) {
        var components = URLComponents(string: "https://api.github.com/search/issues")!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "per_page", value: String(perPage))]
        // "+" in the ISO time zone would otherwise read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        fetchJSON(request, errorKey: "message") { result in
            completion(result.flatMap { body in
                guard let total = (body["total_count"] as? NSNumber)?.intValue else {
                    return .failure(ServiceError.badResponse)
                }
                return .success((total, body["items"] as? [[String: Any]] ?? []))
            })
        }
    }
}

private func isoDateTime(_ date: Date) -> String { return isoPlain.string(from: date) }
