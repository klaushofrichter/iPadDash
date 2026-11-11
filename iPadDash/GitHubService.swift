import Foundation

// Pull request activity across the repositories owned by klaushofrichter, via
// GitHub's search API and a fine-grained token (Pull requests: read-only on all
// repositories). Each refresh is three searches: open PRs (at least 15 minutes old,
// oldest first), merged in the last 24 h (count only), and merged in the last 30
// days (count and the newest ones, via GraphQL for their target branch).

struct MergedPR {
    let repo: String
    let number: Int
    let title: String
    let mergedAt: Date
    let base: String            // target branch, e.g. "main" or "production"
}

struct OpenPR: Equatable {
    let repo: String
    let number: Int
    let title: String
    let created: Date
}

/// Open PRs younger than this are taken to be work in progress and left out.
let openPRMinAge: TimeInterval = 15 * 60

struct GitHubSnapshot {
    /// All open PRs at least `openPRMinAge` old; `openPRs` holds the oldest 100 of them.
    var openCount = 0
    var openPRs: [OpenPR] = []                          // oldest first
    var merged24h = 0
    var merged30d = 0
    var recentMerges: [MergedPR] = []                   // newest first

    /// This many open PRs or more is an alert.
    static let manyOpen = 5
    /// An open PR older than this is overdue, and an alert on its own.
    static let overdueAge: TimeInterval = 24 * 3600

    func overdue(now: Date) -> [OpenPR] {
        return openPRs.filter { now.timeIntervalSince($0.created) > GitHubSnapshot.overdueAge }
    }

    /// "6 open PRs · older than 15 minutes", and "Open PR in art · for 2 days" or
    /// "3 open PRs · older than 1 day, oldest 4 days".
    func alerts(now: Date) -> [PageAlert] {
        var alerts: [PageAlert] = []
        if openCount >= GitHubSnapshot.manyOpen {
            alerts.append(PageAlert(counted(openCount, "open PR"), "older than \(durationText(openPRMinAge))"))
        }
        let overdue = self.overdue(now: now)
        if let oldest = overdue.first {
            let age = durationText(now.timeIntervalSince(oldest.created))
            if overdue.count == 1 {
                alerts.append(PageAlert("Open PR in \(oldest.repo)", "for \(age)"))
            } else {
                alerts.append(PageAlert(counted(overdue.count, "open PR"),
                                        "older than \(durationText(GitHubSnapshot.overdueAge)), oldest \(age)"))
            }
        }
        return alerts
    }
}

final class GitHubService {
    let owner = "klaushofrichter"
    private let token = Secrets.string("GitHubToken")

    /// Completes on the main queue; fails if any of the searches fails.
    func fetchSnapshot(completion: @escaping (Result<GitHubSnapshot, Error>) -> Void) {
        guard token != nil else { return completion(.failure(ServiceError.missing("GitHub token"))) }
        let now = Date()
        var snapshot = GitHubSnapshot()
        let group = FetchGroup()

        func search(_ query: String, perPage: Int, sort: String? = nil, order: String? = nil,
                    _ apply: @escaping (Int, [[String: Any]]) -> Void) {
            self.search(query, perPage: perPage, sort: sort, order: order, completion: group.collect { apply($0.0, $0.1) })
        }

        search("is:pr is:open archived:false user:\(owner) created:<=\(isoDateTime(now.addingTimeInterval(-openPRMinAge)))",
               perPage: 100, sort: "created", order: "asc") { total, items in
            snapshot.openCount = total
            snapshot.openPRs = items.compactMap { item -> OpenPR? in
                guard let created = parseDate(item["created_at"]),
                      let number = (item["number"] as? NSNumber)?.intValue else { return nil }
                return OpenPR(repo: GitHubService.repoName(item), number: number,
                              title: item["title"] as? String ?? "", created: created)
            }.sorted { $0.created < $1.created }
        }
        search("is:pr is:merged user:\(owner) merged:>=\(isoDateTime(now.addingTimeInterval(-86400)))",
               perPage: 1) { total, _ in
            snapshot.merged24h = total
        }
        // GraphQL rather than REST search, so each merge comes with its target branch.
        // Sorted by last update, which for merged PRs is (nearly always) the merge;
        // re-sorted by merge time below.
        let query = "is:pr is:merged user:\(owner) merged:>=\(isoDateTime(now.addingTimeInterval(-30 * 86400))) sort:updated-desc"
        graphQLSearch(query, first: 50, completion: group.collect { (total: Int, nodes: [[String: Any]]) in
            snapshot.merged30d = total
            snapshot.recentMerges = nodes.compactMap { node -> MergedPR? in
                guard let merged = parseDate(node["mergedAt"]),
                      let number = (node["number"] as? NSNumber)?.intValue else { return nil }
                let repo = (node["repository"] as? [String: Any])?["name"] as? String ?? "?"
                return MergedPR(repo: repo, number: number, title: node["title"] as? String ?? "",
                                mergedAt: merged, base: node["baseRefName"] as? String ?? "?")
            }.sorted { $0.mergedAt > $1.mergedAt }
        })

        group.notify {
            if let error = group.firstError {
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

    private func search(_ query: String, perPage: Int, sort: String?, order: String?,
                        completion: @escaping (Result<(Int, [[String: Any]]), Error>) -> Void) {
        var parameters = ["q": query, "per_page": String(perPage)]
        parameters["sort"] = sort
        parameters["order"] = order
        var request = URLRequest(url: url(URL(string: "https://api.github.com/search/issues")!,
                                          query: parameters))
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
