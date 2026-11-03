import Foundation

/// Whether the app can reach anything, judged from the pages' own fetches: any
/// HTTP response (even an error status) proves the network works, so one service
/// being down doesn't count. The root view shows a banner after `offlineAlertAfter`.
final class Connectivity {
    static let shared = Connectivity()
    static let didChange = Notification.Name("Connectivity.didChange")

    /// When requests started failing with no response from anywhere in between.
    private(set) var offlineSince: Date?

    #if DEBUG
    // simctl launch ... with SIMCTL_CHILD_IPADDASH_OFFLINE_AGE=<minutes> fails every
    // request and back-dates the outage; IPADDASH_OFFLINE_SECS=<n> ends it after n seconds.
    private let debugAge = ProcessInfo.processInfo.environment["IPADDASH_OFFLINE_AGE"].flatMap(Double.init)
    private let debugEnd = ProcessInfo.processInfo.environment["IPADDASH_OFFLINE_SECS"]
        .flatMap(Double.init).map { Date().addingTimeInterval($0) }
    fileprivate var debugFailing: Bool {
        return debugAge != nil && (debugEnd.map { Date() < $0 } ?? true)
    }
    #endif

    /// How long the network has been gone, or nil while it works.
    func offlineDuration(now: Date = Date()) -> TimeInterval? {
        return offlineSince.map { now.timeIntervalSince($0) }
    }

    fileprivate func requestFinished(gotResponse: Bool) {
        DispatchQueue.main.async {
            if gotResponse {
                guard self.offlineSince != nil else { return }
                self.offlineSince = nil
            } else {
                guard self.offlineSince == nil else { return }
                self.offlineSince = Date()
                #if DEBUG
                if let age = self.debugAge { self.offlineSince = Date().addingTimeInterval(-age * 60) }
                #endif
            }
            NotificationCenter.default.post(name: Connectivity.didChange, object: nil)
        }
    }
}

extension URLSession {
    /// `dataTask` that also tells `Connectivity` how the request went.
    func trackedDataTask(with request: URLRequest,
                         completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask {
        var request = request
        #if DEBUG
        if Connectivity.shared.debugFailing { request.url = URL(string: "http://127.0.0.1:9/") }
        #endif
        return dataTask(with: request) { data, response, error in
            Connectivity.shared.requestFinished(gotResponse: response != nil)
            completionHandler(data, response, error)
        }
    }
}
