import Foundation
import Network
import UIKit

/// A TP-Link Kasa plug (HS105, HS100, ...) on the local network, spoken to directly
/// in its own protocol on TCP port 9999: JSON, XOR-obfuscated (autokey 171) behind
/// a 4-byte length. No account or cloud. Newer Kasa firmware may require a login
/// instead, so the plugs' firmware should not be updated.
final class KasaPlug {
    let host: String
    private let queue = DispatchQueue(label: "KasaPlug")

    init(host: String) { self.host = host }

    /// Sends one command; completes on the main queue.
    func send(_ command: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let port = NWEndpoint.Port(rawValue: 9999),
              let body = try? JSONSerialization.data(withJSONObject: command) else {
            return completion(.failure(ServiceError.badResponse))
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        var finished = false
        func finish(_ result: Result<[String: Any], Error>) {
            guard !finished else { return }
            finished = true
            connection.cancel()
            DispatchQueue.main.async { completion(result) }
        }
        queue.asyncAfter(deadline: .now() + 6) { finish(.failure(ServiceError.api("no answer"))) }

        connection.stateUpdateHandler = { state in
            switch state {
            case .failed(let error): finish(.failure(error))
            case .waiting(let error): finish(.failure(error))
            default: break
            }
        }
        var length = UInt32(body.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(KasaPlug.scramble(body))
        connection.send(content: packet, completion: .contentProcessed { error in
            if let error = error { finish(.failure(error)) }
        })
        var received = Data()
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data = data { received.append(data) }
                if received.count >= 4 {
                    let size = received.prefix(4).reduce(0) { $0 << 8 | Int($1) }
                    if received.count >= 4 + size {
                        let plain = KasaPlug.unscramble(received.subdata(in: 4..<(4 + size)))
                        if let json = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] {
                            return finish(.success(json))
                        }
                        return finish(.failure(ServiceError.badResponse))
                    }
                }
                if let error = error { return finish(.failure(error)) }
                if isComplete { return finish(.failure(ServiceError.badResponse)) }
                receive()
            }
        }
        receive()
        connection.start(queue: queue)
    }

    private static func scramble(_ data: Data) -> Data {
        var key: UInt8 = 171
        return Data(data.map { byte -> UInt8 in key ^= byte; return key })
    }

    private static func unscramble(_ data: Data) -> Data {
        var key: UInt8 = 171
        return Data(data.map { byte -> UInt8 in defer { key = byte }; return key ^ byte })
    }
}

/// Keeps the battery between 30 % and 80 % by switching the Kasa plug the charger
/// is plugged into (Settings.chargePlug): on at 30 %, off at 80 %. Whenever the plug
/// is off, a countdown rule on the plug itself turns it back on within two hours
/// unless the app keeps re-arming it, so a crashed app or lost Wi-Fi can't let the
/// iPad run flat.
final class ChargeControl {
    static let shared = ChargeControl()
    static let didChange = Notification.Name("ChargeControlDidChange")

    static let onBelow: Float = 0.30
    static let offAbove: Float = 0.80
    private let checkInterval: TimeInterval = 5 * 60
    private let watchdogDelay = 2 * 60 * 60        // seconds until the plug turns itself on
    private let rearmBelow = 60 * 60               // re-arm when less than this is left
    private let ruleName = "iPadDash"

    /// The plug's relay as last read; nil before the first answer or with no plug set.
    private(set) var plugOn: Bool?
    private(set) var lastContact: Date?
    private(set) var lastError: String?
    private var failingSince: Date?
    private var plugOnSince: Date?
    private var plug: KasaPlug?
    private var busy = false
    private var timer: Timer?

    var isOn: Bool { return plug != nil }

    /// 0...1, or nil where iOS doesn't know (simulator).
    var batteryLevel: Float? {
        #if DEBUG
        if let fake = ProcessInfo.processInfo.environment["IPADDASH_BATTERY"].flatMap(Float.init) { return fake }
        #endif
        let level = UIDevice.current.batteryLevel
        return level < 0 ? nil : level
    }

    /// Whether external power is reaching the iPad.
    var isPowered: Bool {
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
    }

    func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            center.addObserver(self, selector: #selector(batteryChanged), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(settingsChanged), name: Settings.didChange, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.check()
        }
        settingsChanged()
    }

    /// Red items for the summary page and the footer.
    var alerts: [PageAlert] {
        var items: [PageAlert] = []
        let now = Date()
        if let level = batteryLevel, level < 0.2, !isPowered {
            items.append(PageAlert("Battery low", "\(Int((level * 100).rounded()))%"))
        }
        if let since = failingSince, now.timeIntervalSince(since) >= 15 * 60 {
            items.append(PageAlert("Charging plug", "unreachable · \(durationText(now.timeIntervalSince(since)))"))
        }
        if plugOn == true, !isPowered, let since = plugOnSince, now.timeIntervalSince(since) >= 10 * 60 {
            items.append(PageAlert("Not charging", "plug is on"))
        }
        return items
    }

    /// "76% charging" for the footer.
    var batteryText: String? {
        guard let level = batteryLevel else { return nil }
        return "\(Int((level * 100).rounded()))% " + (isPowered ? "charging" : "on battery")
    }

    @objc private func batteryChanged() {
        changed()
        // Act right at the thresholds instead of up to five minutes later.
        if let level = batteryLevel, (plugOn == true && level >= ChargeControl.offAbove)
            || (plugOn == false && level <= ChargeControl.onBelow) {
            check()
        }
    }

    @objc private func settingsChanged() {
        let host = Settings.chargePlug
        guard host != plug?.host ?? "" else { return }
        // Leave a plug that is no longer used switched on, without a countdown.
        if let old = plug {
            old.send(["system": ["set_relay_state": ["state": 1]]]) { _ in
                old.send(["count_down": ["delete_all_rules": [:]]]) { _ in }
            }
        }
        plug = host.isEmpty ? nil : KasaPlug(host: host)
        plugOn = nil
        plugOnSince = nil
        lastContact = nil
        lastError = nil
        failingSince = nil
        changed()
        check()
    }

    /// Reads the plug and switches it if the battery calls for it.
    func check() {
        guard let plug = plug, !busy else { return }
        busy = true
        plug.send(["system": ["get_sysinfo": [:]], "count_down": ["get_rules": [:]]]) { result in
            switch result {
            case .failure(let error):
                self.failed(error)
            case .success(let json):
                guard let info = (json["system"] as? [String: Any])?["get_sysinfo"] as? [String: Any],
                      let relay = (info["relay_state"] as? NSNumber)?.intValue else {
                    return self.failed(ServiceError.badResponse)
                }
                let rules = ((json["count_down"] as? [String: Any])?["get_rules"] as? [String: Any])?["rule_list"]
                    as? [[String: Any]] ?? []
                let remain = rules.compactMap { rule -> Int? in
                    guard (rule["enable"] as? NSNumber)?.intValue == 1, (rule["act"] as? NSNumber)?.intValue == 1
                    else { return nil }
                    return (rule["remain"] as? NSNumber)?.intValue
                }.max()
                self.succeeded(relayOn: relay == 1)
                self.act(on: plug, relayOn: relay == 1, watchdogLeft: remain)
            }
        }
    }

    private func act(on plug: KasaPlug, relayOn: Bool, watchdogLeft: Int?) {
        guard let level = batteryLevel else { return done() }
        if relayOn && level >= ChargeControl.offAbove {
            // The plug only runs a "turn on" countdown while it is off, so arm it after
            // switching off; if that fails, switch back on rather than stay off unguarded.
            setRelay(plug, on: false) {
                guard self.plugOn == false else { return self.done() }
                self.arm(plug) { ok in
                    if ok { return self.done() }
                    self.setRelay(plug, on: true) { self.done() }
                }
            }
        } else if !relayOn && level <= ChargeControl.onBelow {
            setRelay(plug, on: true) {
                plug.send(["count_down": ["delete_all_rules": [:]]]) { _ in self.done() }
            }
        } else if !relayOn && (watchdogLeft ?? 0) < rearmBelow {
            arm(plug) { _ in self.done() }
        } else {
            done()
        }
    }

    /// Replaces the plug's countdown rules with "turn on in two hours".
    private func arm(_ plug: KasaPlug, completion: @escaping (Bool) -> Void) {
        plug.send(["count_down": ["delete_all_rules": [:]]]) { result in
            if case .failure(let error) = result { self.failed(error); return completion(false) }
            plug.send(["count_down": ["add_rule": ["enable": 1, "delay": self.watchdogDelay,
                                                   "act": 1, "name": self.ruleName]]]) { result in
                if case .failure(let error) = result { self.failed(error); return completion(false) }
                completion(true)
            }
        }
    }

    private func setRelay(_ plug: KasaPlug, on: Bool, completion: @escaping () -> Void) {
        plug.send(["system": ["set_relay_state": ["state": on ? 1 : 0]]]) { result in
            switch result {
            case .failure(let error): self.failed(error)
            case .success: self.succeeded(relayOn: on)
            }
            completion()
        }
    }

    private func succeeded(relayOn: Bool) {
        if relayOn && plugOn != true { plugOnSince = Date() }
        plugOn = relayOn
        lastContact = Date()
        lastError = nil
        failingSince = nil
        changed()
    }

    private func failed(_ error: Error) {
        lastError = error.localizedDescription
        if failingSince == nil { failingSince = Date() }
        busy = false
        changed()
    }

    private func done() {
        busy = false
    }

    private func changed() {
        NotificationCenter.default.post(name: ChargeControl.didChange, object: nil)
    }
}
