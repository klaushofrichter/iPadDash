import Foundation
import Network
import UIKit

/// A TP-Link Kasa plug (HS105, HS100, ...) on the local network, spoken to directly
/// in its own protocol on TCP port 9999: JSON, XOR-obfuscated (autokey 171) behind
/// a 4-byte length. No account or cloud. Newer Kasa firmware may require a login
/// instead, so the plugs' firmware should not be updated.
final class KasaPlug {
    let host: String
    /// One queue for all plugs: a search talks to a whole network of addresses at once.
    private static let queue = DispatchQueue(label: "KasaPlug")

    init(host: String) { self.host = host }

    // The commands, and the status in the answer to `sysinfoQuery`.
    static let sysinfoQuery: [String: Any] = ["system": ["get_sysinfo": [:]]]
    static let clearRules: [String: Any] = ["count_down": ["delete_all_rules": [:]]]
    static func relay(_ on: Bool) -> [String: Any] { return ["system": ["set_relay_state": ["state": on ? 1 : 0]]] }
    static func sysinfo(in json: [String: Any]) -> [String: Any]? {
        return (json["system"] as? [String: Any])?["get_sysinfo"] as? [String: Any]
    }

    /// Sends one command; completes on the main queue, after `timeout` at the latest.
    func send(_ command: [String: Any], timeout: TimeInterval = 6,
              completion: @escaping (Result<[String: Any], Error>) -> Void) {
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
        KasaPlug.queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(ServiceError.api("no answer"))) }

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
        connection.start(queue: KasaPlug.queue)
    }

    static func scramble(_ data: Data) -> Data {
        var key: UInt8 = 171
        return Data(data.map { byte -> UInt8 in key ^= byte; return key })
    }

    static func unscramble(_ data: Data) -> Data {
        var key: UInt8 = 171
        return Data(data.map { byte -> UInt8 in defer { key = byte }; return key ^ byte })
    }
}

/// Finds a Kasa plug by the name it has in the Kasa app ("Garland"): the router may
/// hand a plug a new address at any time, the name stays.
enum KasaSearch {
    /// Whether `text` is an IPv4 address rather than a plug's name.
    static func isAddress(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy({ $0.isASCII && $0.isNumber }) && Int(part)! <= 255
        }
    }

    /// The other addresses of the /24 network `address` is in (home networks are).
    static func neighbors(of address: String) -> [String] {
        guard isAddress(address) else { return [] }
        let parts = address.split(separator: ".")
        let prefix = parts.prefix(3).joined(separator: ".")
        return (1...254).filter { $0 != Int(parts[3]) }.map { "\(prefix).\($0)" }
    }

    /// Whether a plug's name matches the one in the setting: case and outer spaces don't count.
    static func matches(_ alias: String, _ name: String) -> Bool {
        func plain(_ s: String) -> String { return s.trimmingCharacters(in: .whitespaces).lowercased() }
        return plain(alias) == plain(name)
    }

    /// Asks every address on the iPad's network for its Kasa name (a read-only
    /// status request) and completes on the main queue with the address of the
    /// plug called `name`, or nil if none answers to it.
    static func find(named name: String, completion: @escaping (String?) -> Void) {
        guard let own = NetworkBatteryPageViewController.ipv4Address() else { return completion(nil) }
        let group = DispatchGroup()
        var found: String?
        for host in neighbors(of: own) {
            group.enter()
            KasaPlug(host: host).send(KasaPlug.sysinfoQuery, timeout: 4) { result in
                if case .success(let json) = result,
                   let alias = KasaPlug.sysinfo(in: json)?["alias"] as? String, matches(alias, name) {
                    found = found ?? host
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(found) }
    }
}

/// Keeps the battery between 40 % and 70 % by switching the Kasa plug the charger
/// is plugged into (Settings.chargePlug, the plug's name or its address): on at 40 %, off at 70 %. A narrow band in
/// the middle keeps a battery that is always near power from sitting at a high
/// charge, which ages it and can make it swell. Whenever the plug
/// is off, a countdown rule on the plug itself turns it back on within two hours
/// unless the app keeps re-arming it, so a crashed app or lost Wi-Fi can't let the
/// iPad run flat.
final class ChargeControl {
    static let shared = ChargeControl()
    static let didChange = Notification.Name("ChargeControlDidChange")

    static let onBelow: Float = 0.40
    static let offAbove: Float = 0.70
    /// Below this, off power, the battery is red.
    static let lowBelow: Float = 0.20
    private let checkInterval: TimeInterval = 5 * 60
    /// While charging, check every minute so the plug goes off close to `offAbove`
    /// (at five minutes the battery got some 10 % past it).
    private let chargingCheckInterval: TimeInterval = 60
    private var lastCheck = Date.distantPast
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
    /// The setting the plug was made from: a name or an address; empty = none.
    private var setting = ""
    /// The plug's name when the setting is one; its address is then searched for.
    private var plugName: String? { return setting.isEmpty || KasaSearch.isAddress(setting) ? nil : setting }
    private var searching = false
    private var lastSearch = Date.distantPast
    /// A plug that stops answering is searched for again this far apart: five minutes
    /// at first, doubling up to an hour while it stays lost (a search asks every
    /// address on the network).
    private var searchInterval = ChargeControl.firstSearchInterval
    private static let firstSearchInterval: TimeInterval = 5 * 60
    /// The address last found for a plug's name, kept across launches.
    private let foundHostKey = "chargePlugFoundHost", foundNameKey = "chargePlugFoundName"
    /// The plug the check under way is talking to; nil when none runs.
    private var checking: KasaPlug?
    /// Waiting for the check under way.
    private var checkCompletions: [() -> Void] = []
    private var timer: Timer?

    var isOn: Bool { return !setting.isEmpty }
    /// The address in use, e.g. the one found for the plug's name.
    var plugAddress: String? { return plug?.host }

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
        #if DEBUG
        if ProcessInfo.processInfo.environment["IPADDASH_POWERED"] != nil { return true }
        #endif
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
        timer = Timer.scheduledTimer(withTimeInterval: chargingCheckInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let interval = self.plugOn == true ? self.chargingCheckInterval : self.checkInterval
            if Date().timeIntervalSince(self.lastCheck) >= interval - 1 { self.check() }
        }
        settingsChanged()
    }

    /// Battery level in whole percent.
    var batteryPercent: Int? {
        return batteryLevel.map { Int(($0 * 100).rounded()) }
    }

    /// Below `lowBelow` and off power.
    var isLow: Bool {
        guard let level = batteryLevel else { return false }
        return level < ChargeControl.lowBelow && !isPowered
    }

    /// How long the plug hasn't answered, once that is 15 minutes or more.
    var plugUnreachableFor: TimeInterval? {
        guard let since = failingSince else { return nil }
        let duration = Date().timeIntervalSince(since)
        return duration >= 15 * 60 ? duration : nil
    }

    /// The plug has been on for 10 minutes and the iPad still gets no power.
    var notCharging: Bool {
        guard plugOn == true, !isPowered, let since = plugOnSince else { return false }
        return Date().timeIntervalSince(since) >= 10 * 60
    }

    /// Red items for the summary page and the Network & Battery page.
    var alerts: [PageAlert] {
        var items: [PageAlert] = []
        if isLow, let percent = batteryPercent { items.append(PageAlert("Battery low", "\(percent)%")) }
        if let duration = plugUnreachableFor {
            items.append(PageAlert("Charging plug", "unreachable · \(durationText(duration))"))
        }
        if notCharging { items.append(PageAlert("Not charging", "plug is on")) }
        return items
    }

    /// "Battery 76% charging".
    var batteryText: String? {
        guard let percent = batteryPercent else { return nil }
        return "Battery \(percent)% " + (isPowered ? "charging" : "on battery")
    }

    /// "on · checked 9:41 AM", "off · unreachable", "contacting…"; with
    /// `showingError`, the error itself instead of "unreachable".
    func plugStatusText(showingError: Bool = false) -> String {
        guard isOn else { return "not set up" }
        if plug == nil, let name = plugName {
            return searching ? "searching for “\(name)”…" : "“\(name)” not found on this network"
        }
        var parts: [String] = []
        if let on = plugOn { parts.append(on ? "on" : "off") }
        if let error = lastError {
            parts.append(showingError ? error : "unreachable")
        } else if let contact = lastContact {
            parts.append("checked \(timeOfDayFormatter.string(from: contact))")
        } else {
            parts.append("contacting…")
        }
        return parts.joined(separator: " · ")
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
        guard Settings.chargePlug != setting else { return }
        setting = Settings.chargePlug
        // Leave a plug that is no longer used switched on, without a countdown.
        if let old = plug {
            old.send(KasaPlug.relay(true)) { _ in old.send(KasaPlug.clearRules) { _ in } }
        }
        if let name = plugName {
            // Start from the address found last time; a failed check searches again.
            let defaults = UserDefaults.standard
            let known = defaults.string(forKey: foundNameKey) == name ? defaults.string(forKey: foundHostKey) : nil
            plug = known.map { KasaPlug(host: $0) }
            lastSearch = .distantPast
            searchInterval = ChargeControl.firstSearchInterval
        } else {
            plug = setting.isEmpty ? nil : KasaPlug(host: setting)
        }
        plugOn = nil
        plugOnSince = nil
        lastContact = nil
        lastError = nil
        failingSince = nil
        changed()
        check()   // if one is under way, `done` checks the new plug right after
    }

    /// Reads the plug and switches it if the battery calls for it. `completion` runs
    /// once the plug has answered or failed to (at once when no plug is set up).
    func check(completion: (() -> Void)? = nil) {
        if let completion = completion { checkCompletions.append(completion) }
        guard let plug = plug else {
            search()   // a plug set by name whose address isn't known yet
            return finishCompletions()
        }
        guard checking == nil else { return }
        checking = plug
        lastCheck = Date()
        plug.send(["system": ["get_sysinfo": [:]], "count_down": ["get_rules": [:]]]) { result in
            switch result {
            case .failure(let error):
                self.failed(error)
                self.done()
            case .success(let json):
                guard let info = KasaPlug.sysinfo(in: json),
                      let relay = (info["relay_state"] as? NSNumber)?.intValue else {
                    self.failed(ServiceError.badResponse)
                    return self.done()
                }
                // The address may have gone to another Kasa plug: never switch that one.
                if let name = self.plugName, let alias = info["alias"] as? String, !KasaSearch.matches(alias, name) {
                    self.plug = nil
                    self.plugOn = nil
                    self.lastSearch = .distantPast
                    self.failed(ServiceError.api("that address is now “\(alias)”"))   // searches for the name
                    return self.done()
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
                plug.send(KasaPlug.clearRules) { _ in self.done() }
            }
        } else if !relayOn && (watchdogLeft ?? 0) < rearmBelow {
            arm(plug) { _ in self.done() }
        } else {
            done()
        }
    }

    /// Replaces the plug's countdown rules with "turn on in two hours".
    private func arm(_ plug: KasaPlug, completion: @escaping (Bool) -> Void) {
        plug.send(KasaPlug.clearRules) { result in
            if case .failure(let error) = result { self.failed(error); return completion(false) }
            plug.send(["count_down": ["add_rule": ["enable": 1, "delay": self.watchdogDelay,
                                                   "act": 1, "name": self.ruleName]]]) { result in
                if case .failure(let error) = result { self.failed(error); return completion(false) }
                completion(true)
            }
        }
    }

    private func setRelay(_ plug: KasaPlug, on: Bool, completion: @escaping () -> Void) {
        plug.send(KasaPlug.relay(on)) { result in
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
        changed()
        search()   // it may have a new address
    }

    /// The check is over, whatever came of it.
    private func done() {
        let checked = checking
        checking = nil
        // The plug was changed meanwhile: those waiting get the new plug's answer.
        if plug !== checked { return check() }
        finishCompletions()
    }

    /// Looks for the plug by its name, at most every `searchInterval`, and checks it
    /// at its new address if that changed. Nothing to do for a plug set by address.
    private func search() {
        guard let name = plugName, !searching, Date().timeIntervalSince(lastSearch) >= searchInterval else { return }
        searching = true
        lastSearch = Date()
        changed()
        KasaSearch.find(named: name) { host in
            self.searching = false
            guard self.plugName == name else { return }   // the setting changed meanwhile
            guard let host = host else {
                self.searchInterval = min(self.searchInterval * 2, 3600)
                // (`failed` searches again, which the interval just set puts off.)
                if self.plug == nil { self.failed(ServiceError.api("“\(name)” not found")) } else { self.changed() }
                return
            }
            self.searchInterval = ChargeControl.firstSearchInterval
            guard host != self.plug?.host else { return self.changed() }
            UserDefaults.standard.set(host, forKey: self.foundHostKey)
            UserDefaults.standard.set(name, forKey: self.foundNameKey)
            self.plug = KasaPlug(host: host)
            self.changed()
            self.check()
        }
    }

    private func finishCompletions() {
        let completions = checkCompletions
        checkCompletions = []
        completions.forEach { $0() }
    }

    private func changed() {
        NotificationCenter.default.post(name: ChargeControl.didChange, object: nil)
    }
}
