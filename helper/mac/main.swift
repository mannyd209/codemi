// CodeMi Helper for macOS.
//
// Keeps a WebSocket open to the CodeMi relay so the CodeMi iPhone app can check Kimi Code's
// Remote Control and turn it back on while Remote Control itself is off. It reads the Remote
// Control status, Kimi Code's version and whether Kimi Code has downloaded an update, turns
// Remote Control on (opening Kimi Code first if it was quit), and, when asked, restarts Kimi Code
// so the update Kimi Code downloaded itself gets installed. It never runs any other command.
//
// Config: ~/Library/Application Support/CodeMi Helper/config.json
//   {"relay": "...", "secrets": ["...", ...], "secret": "..."}
// Each pairing (one per iPhone or iPad that installed the helper, up to 8) has its own
// connection, so installing from another device never cuts off the ones already paired, and
// removing it from one device only drops that device's pairing (the last one removes the helper).
// "secret" alone is the 0.2 format, still read.

import Foundation

import AppKit

let helperVersion = "0.4.2"
let home = FileManager.default.homeDirectoryForCurrentUser
let kimiHome = home.appendingPathComponent(".kimi-code")
let configURL = ProcessInfo.processInfo.environment["CODEMI_HELPER_CONFIG"].map { URL(fileURLWithPath: $0) }
    ?? home.appendingPathComponent("Library/Application Support/CodeMi Helper/config.json")
let stateURL = configURL.deletingLastPathComponent().appendingPathComponent("state.json")
let kimiBundleId = "com.kimi.code.desktop"

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
}

struct Config: Codable {
    let relay: String
    var secret: String?
    var secrets: [String]?

    /// Every pairing, newest first, without repeats.
    var pairings: [String] {
        var seen = Set<String>()
        return ((secrets ?? []) + [secret].compactMap { $0 }).filter { seen.insert($0).inserted }
    }
}

// MARK: - Kimi Code local API

struct KimiStatus: Codable, Equatable {
    var running: Bool
    var enabled: Bool?
    var state: String?
    var deviceId: String?
    var deviceName: String?
    var error: String?
    /// The Mac's own name (System Settings → General → Sharing), known even while Remote Control is off.
    var computerName: String? = Host.current().localizedName
    /// Kimi Code's version and updates (helper 0.4+).
    var app: KimiApp.Info? = KimiApp.info()
}

// MARK: - Kimi Code's version and updates

/// What the helper remembers between runs (state.json next to the config).
struct HelperState: Codable {
    /// Turn Remote Control back on when Kimi Code comes back after a restart or update with it off.
    var autoReconnect: Bool = true
    /// The Kimi Code version seen last, to notice when it changes.
    var seenVersion: String?
    /// The last time Kimi Code's version changed, and whether CodeMi's Install Now did it.
    var updated: KimiApp.Updated?
    /// The downloaded update an alert already went out for.
    var alertedVersion: String?

    static func load() -> HelperState {
        (try? JSONDecoder().decode(HelperState.self, from: Data(contentsOf: stateURL))) ?? HelperState()
    }
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }
}

enum KimiApp {
    struct Updated: Codable, Equatable { let from: String; let to: String; let byPhone: Bool }
    struct Info: Codable, Equatable {
        var version: String?
        /// The newest version on Kimi's update feed.
        var latest: String?
        /// A newer version Kimi Code has downloaded and installs the next time it quits.
        var ready: String?
        /// The version Install Now is installing right now.
        var installing: String?
        var updated: Updated?
        var autoReconnect: Bool
        /// Where Kimi publishes each version's notes: <notes><version>/changelog.en.md
        var notes: String?
    }

    static var installing: String?
    static var latest: (version: String, checked: Date)?

    static func bundleURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: kimiBundleId)
    }
    static func version() -> String? {
        guard let url = bundleURL() else { return nil }
        return NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }
    /// Kimi Code's update feed (from the app's own app-update.yml), e.g. https://code.kimi.com/kimi-code/desktop/
    static func feed() -> String? {
        guard let url = bundleURL(),
              let yml = try? String(contentsOf: url.appendingPathComponent("Contents/Resources/app-update.yml"), encoding: .utf8),
              let line = yml.split(separator: "\n").first(where: { $0.hasPrefix("url:") }) else { return nil }
        let value = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
        return value.hasSuffix("/") ? value : value + "/"
    }
    /// The update Kimi Code downloaded (it saves it in its updater cache until it's installed).
    static func downloaded() -> String? {
        let info = home.appendingPathComponent("Library/Caches/kimi-code-app-updater/pending/update-info.json")
        guard let data = try? Data(contentsOf: info),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["fileName"] as? String,
              FileManager.default.fileExists(atPath: info.deletingLastPathComponent().appendingPathComponent(name).path),
              let match = name.range(of: #"[0-9]+(\.[0-9]+)+"#, options: .regularExpression) else { return nil }
        return String(name[match])
    }
    static func newer(_ a: String?, than b: String?) -> Bool {
        guard let a, let b else { return false }
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
    static func info() -> Info? {
        guard let version = version() else { return nil }
        let state = HelperState.load()
        let ready = downloaded().flatMap { newer($0, than: version) ? $0 : nil }
        let latest = latest.map { $0.version }.flatMap { newer($0, than: version) ? $0 : nil }
        return Info(version: version, latest: latest ?? ready, ready: ready, installing: installing,
                    updated: state.updated, autoReconnect: state.autoReconnect, notes: feed().map { $0 + "binaries/" })
    }
    /// Checks Kimi's update feed (at most every 30 minutes).
    static func checkFeed() async {
        if let latest, Date().timeIntervalSince(latest.checked) < 30 * 60 { return }
        guard let feed = feed(), let url = URL(string: feed + "latest-mac.yml"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let text = String(data: data, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("version:") }) else { return }
        latest = (line.dropFirst(8).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "'", with: ""), Date())
    }
    static func running() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: kimiBundleId).first
    }
    static func open() {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-b", kimiBundleId]
        try? open.run()
        open.waitUntilExit()
    }

    /// Whether any Kimi Code session is in the middle of a turn.
    static func busy() async -> Bool {
        guard let data = try? await Kimi.call("GET", "sessions?limit=50"),
              let items = data["items"] as? [[String: Any]] else { return false }
        return items.contains { $0["busy"] as? Bool == true }
    }

    /// Checks Install Now can go ahead: nil if it can, or why not.
    static func installProblem() async -> String? {
        if installing != nil { return "already_installing" }
        guard let version = version() else { return "kimi_not_installed" }
        guard let ready = downloaded(), newer(ready, than: version) else { return "no_update" }
        if Kimi.origin() != nil, await busy() { return "busy" }
        return nil
    }

    /// Quits Kimi Code (which installs the update it downloaded), waits for the new version,
    /// opens it again and turns Remote Control back on.
    static func install() async -> (ok: Bool, error: String?) {
        guard let from = version(), let to = downloaded() else { return (false, "no_update") }
        installing = to
        defer { installing = nil }
        log("Installing Kimi Code \(to) (from \(from))")
        if running() == nil {
            // The downloaded update only installs when Kimi Code quits, so open it first and give
            // its updater a moment to pick the download up again.
            open()
            for _ in 0..<60 where Kimi.origin() == nil { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
        if let app = running() {
            // Kimi Code asks "Quit Kimi Code?" while Remote Control is on, and nobody is at the
            // computer to answer. Turning Remote Control off first (it comes back on after the
            // update) means it quits without asking.
            if Kimi.origin() != nil, await Kimi.status().enabled == true {
                _ = try? await Kimi.call("POST", "remote-control", body: ["enabled": false])
                for _ in 0..<10 where await Kimi.status().enabled != false { try? await Task.sleep(nanoseconds: 500_000_000) }
            }
            let script = Process()
            script.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            script.arguments = ["-e", "tell application id \"\(kimiBundleId)\" to quit"]
            try? script.run()
            script.waitUntilExit()
            for _ in 0..<30 where !app.isTerminated { try? await Task.sleep(nanoseconds: 500_000_000) }
            if !app.isTerminated {
                // Still asking something (no session was mid-reply, that was checked): close it
                // anyway. Kimi Code's updater installs the update once the app has exited.
                log("Kimi Code didn't quit by itself; closing it")
                app.terminate()
                for _ in 0..<20 where !app.isTerminated { try? await Task.sleep(nanoseconds: 500_000_000) }
                if !app.isTerminated { app.forceTerminate() }
                for _ in 0..<20 where !app.isTerminated { try? await Task.sleep(nanoseconds: 500_000_000) }
            }
            guard app.isTerminated else { log("Kimi Code didn't quit"); return (false, "kimi_did_not_quit") }
        }
        // Kimi Code's updater replaces the app right after it quits.
        for _ in 0..<180 where version() != to { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        let now = version() ?? from
        var state = HelperState.load()
        if now != from {
            state.updated = Updated(from: from, to: now, byPhone: true)
            state.seenVersion = now
            state.save()
            log("Kimi Code is now \(now)")
        } else {
            log("Kimi Code is still \(now) after quitting; opening it again")
        }
        let result = await Kimi.enable()
        return now == to ? (result.ok, result.error) : (false, "update_not_installed")
    }
}

/// Watches Kimi Code between requests: notices when its version changes (an update it installed
/// by itself), turns Remote Control back on after Kimi Code restarts with it off (if the switch is
/// on), and says when a new update is downloaded so the phone can be told.
enum Watcher {
    static var wasOn = false
    static var lastPid: pid_t?
    static var downSince: Date?
    static var waitingSince: Date?
    /// Called when Kimi Code has a new downloaded update to tell the phone about.
    static var onUpdateReady: ((String) -> Void)?

    static func tick() async {
        await KimiApp.checkFeed()
        var state = HelperState.load()
        let version = KimiApp.version()
        if let version, version != state.seenVersion {
            if let seen = state.seenVersion, KimiApp.installing == nil {
                state.updated = KimiApp.Updated(from: seen, to: version, byPhone: false)
                log("Kimi Code updated itself: \(seen) → \(version)")
            }
            state.seenVersion = version
            state.save()
        }
        if let ready = KimiApp.downloaded(), KimiApp.newer(ready, than: version), state.alertedVersion != ready {
            state.alertedVersion = ready
            state.save()
            log("Kimi Code \(ready) is downloaded and ready to install")
            onUpdateReady?(ready)
        }
        guard KimiApp.installing == nil else { return }
        let pid = KimiApp.running()?.processIdentifier
        if pid == nil {
            if lastPid != nil { downSince = Date() }
            lastPid = nil
            return
        }
        if lastPid != pid {
            // Kimi Code (re)started. If Remote Control was on before, give it a moment to come back
            // by itself, then turn it on.
            waitingSince = lastPid == nil && downSince == nil && !wasOn ? nil : Date()
            lastPid = pid
            downSince = nil
        }
        let status = await Kimi.status()
        if status.state == "on" { wasOn = true; waitingSince = nil; return }
        guard let since = waitingSince else { if status.enabled == false { wasOn = false }; return }
        guard wasOn, state.autoReconnect else { waitingSince = nil; return }
        if Date().timeIntervalSince(since) >= 20 {
            waitingSince = nil
            log("Kimi Code came back with Remote Control off; turning it back on")
            let result = await Kimi.enable()
            log("Turn on result: ok=\(result.ok) error=\(result.error ?? "-")")
        }
    }
}

enum Kimi {
    struct Instance: Decodable {
        let pid: Int32
        let host: String?
        let port: Int
        let heartbeat_at: Double?
    }

    static func origin() -> URL? {
        let folder = kimiHome.appendingPathComponent("server/instances")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let live = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Instance.self, from: Data(contentsOf: $0)) }
            .filter { kill($0.pid, 0) == 0 }
            .max { ($0.heartbeat_at ?? 0) < ($1.heartbeat_at ?? 0) }
        guard let live else { return nil }
        return URL(string: "http://\(live.host ?? "127.0.0.1"):\(live.port)/api/v1")
    }

    static func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let origin = origin() else { throw URLError(.cannotConnectToHost) }
        let token = try String(contentsOf: kimiHome.appendingPathComponent("server.token"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: origin.appendingPathComponent(path), timeoutInterval: 10)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard reply["code"] as? Int == 0 else {
            throw NSError(domain: "Kimi", code: reply["code"] as? Int ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: reply["msg"] as? String ?? "Kimi Code API error"])
        }
        return reply["data"] as? [String: Any] ?? [:]
    }

    static func status() async -> KimiStatus {
        guard origin() != nil else { return KimiStatus(running: false) }
        do {
            let data = try await call("GET", "remote-control")
            return KimiStatus(running: true, enabled: data["enabled"] as? Bool, state: data["state"] as? String,
                              deviceId: data["device_id"] as? String, deviceName: data["device_name"] as? String)
        } catch {
            return KimiStatus(running: true, error: error.localizedDescription)
        }
    }

    /// The Kimi plan's usage, as Kimi Code's own Plan usage screen shows it (Kimi Code asks Kimi's
    /// servers). Only the percentages and reset times are passed on:
    /// {"limit5h": {"used": 0.12, "resetAt": "2026-11-05T06:49:48Z"}, "limit7d": …, "monthTotal": …}.
    /// nil when Kimi Code isn't open or its user isn't signed in with a Kimi subscription.
    static func usage() async -> [String: Any]? {
        guard origin() != nil, let data = try? await call("GET", "oauth/usage"),
              data["kind"] as? String == "ok",
              let usages = (data["quota"] as? [String: Any])?["usages"] as? [String: Any] else { return nil }
        var out: [String: Any] = [:]
        for key in ["limit5h", "limit7d", "monthTotal"] {
            guard let entry = usages[key] as? [String: Any], let used = (entry["usedRatio"] as? NSNumber)?.doubleValue else { continue }
            var item: [String: Any] = ["used": used]
            if let reset = entry["resetAt"] as? String { item["resetAt"] = reset }
            out[key] = item
        }
        return out.isEmpty ? nil : out
    }

    /// Opens Kimi Code if needed, turns Remote Control on, and waits until it reports "on".
    static func enable() async -> (ok: Bool, status: KimiStatus, error: String?) {
        if origin() == nil {
            log("Kimi Code isn't running; opening it")
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-g", "-a", "Kimi Code"]
            try? open.run()
            open.waitUntilExit()
            for _ in 0..<30 where origin() == nil { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            if origin() == nil { return (false, await status(), "kimi_not_started") }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        var current = await status()
        if current.enabled == true && current.state == "on" { return (true, current, nil) }
        do {
            _ = try await call("POST", "remote-control", body: ["enabled": true])
        } catch {
            return (false, current, error.localizedDescription)
        }
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            current = await status()
            if current.state == "on" { return (true, current, nil) }
        }
        return (false, current, "still_\(current.state ?? "unknown")")
    }
}

// MARK: - Relay connection

final class RelayClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let relay: String
    /// The pairing this connection is for.
    let secret: String
    var session: URLSession!
    var socket: URLSessionWebSocketTask?
    var lastSent: KimiStatus?
    var backoff: Double = 2
    /// When the relay last answered a ping (nil until the first one goes out).
    var lastPong: Date?
    /// This device removed the helper; the other pairings carry on without it.
    var removed = false

    init(relay: String, secret: String) {
        self.relay = relay
        self.secret = secret
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func connect() {
        guard let url = URL(string: relay.replacingOccurrences(of: "https://", with: "wss://") + "/v1/helper") else {
            log("Bad relay URL"); exit(1)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("macos", forHTTPHeaderField: "X-CodeMi-Platform")
        request.setValue(helperVersion, forHTTPHeaderField: "X-CodeMi-Helper-Version")
        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()
        receive(on: task)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        log("Connected to relay")
        backoff = 2
        Task {
            let status = await Kimi.status()
            lastSent = status
            send(["type": "hello", "status": encode(status)], on: webSocketTask)
        }
    }

    func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, task === self.socket else { return }
            switch result {
            case .success(.string(let text)):
                self.handle(text, on: task)
                self.receive(on: task)
            case .success:
                self.receive(on: task)
            case .failure(let error):
                self.reconnect(after: error.localizedDescription)
            }
        }
    }

    func handle(_ text: String, on task: URLSessionWebSocketTask) {
        guard let message = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = message["type"] as? String, let id = message["id"] as? String else { return }
        Task {
            switch type {
            case "status":
                let status = await Kimi.status()
                lastSent = status
                var reply: [String: Any] = ["type": "status", "id": id, "status": encode(status)]
                // Plan usage only when the phone asks (CodeMi 1.2+); it's never stored anywhere.
                if message["usage"] as? Bool == true, let usage = await Kimi.usage() { reply["usage"] = usage }
                send(reply, on: task)
            case "enable":
                log("Relay asked to turn Remote Control on")
                let result = await Kimi.enable()
                log("Turn on result: ok=\(result.ok) state=\(result.status.state ?? "-") error=\(result.error ?? "-")")
                lastSent = result.status
                var reply: [String: Any] = ["type": "result", "id": id, "ok": result.ok, "status": encode(result.status)]
                if let error = result.error { reply["error"] = error }
                send(reply, on: task)
            case "install":
                // Install the Kimi Code update it downloaded (restarts Kimi Code). Answers right
                // away; the phone follows along in the status.
                if let problem = await KimiApp.installProblem() {
                    send(["type": "result", "id": id, "ok": false, "error": problem, "status": encode(await Kimi.status())], on: task)
                    return
                }
                log("Relay asked to install the Kimi Code update")
                KimiApp.installing = KimiApp.downloaded()
                send(["type": "result", "id": id, "ok": true, "status": encode(await Kimi.status())], on: task)
                KimiApp.installing = nil
                let result = await KimiApp.install()
                log("Install result: ok=\(result.ok) error=\(result.error ?? "-")")
                for client in clients { await client.pushStatus() }
            case "settings":
                var state = HelperState.load()
                if let on = message["autoReconnect"] as? Bool {
                    state.autoReconnect = on
                    state.save()
                    log("Turn Remote Control back on after restarts: \(on ? "on" : "off")")
                }
                send(["type": "result", "id": id, "ok": true, "status": encode(await Kimi.status())], on: task)
            case "uninstall":
                send(["type": "result", "id": id, "ok": true], on: task)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if message["all"] as? Bool == true {
                    // The user chose to remove the helper from this computer for every device.
                    log("A device removed the helper from this computer")
                    Self.uninstallSelf()
                } else if Self.removePairing(secret) {
                    log("A device unpaired; the helper keeps running for its other devices")
                    removed = true
                    socket = nil
                    task.cancel(with: .normalClosure, reason: nil)
                } else {
                    log("The last paired device removed the helper")
                    Self.uninstallSelf()
                }
            default:
                send(["type": "result", "id": id, "ok": false, "error": "unsupported"], on: task)
            }
        }
    }

    /// Drops one pairing from the config. Returns false when it was the last one (or the config
    /// can't be rewritten), in which case the whole helper should go.
    static func removePairing(_ secret: String) -> Bool {
        guard var config = try? JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL)) else { return false }
        let left = config.pairings.filter { $0 != secret }
        guard !left.isEmpty else { return false }
        config.secret = left[0]
        config.secrets = left
        guard let data = try? JSONEncoder().encode(config), (try? data.write(to: configURL, options: .atomic)) != nil else { return false }
        // Pairing codes: readable by this user only, as the installer writes it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        return true
    }

    /// Deletes the helper's files and LaunchAgent, then unloads itself (which ends this process).
    static func uninstallSelf() {
        let label = "com.mannydlabs.codemi.helper"
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        try? FileManager.default.removeItem(at: plist)
        try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent())
        let bootout = Process()
        bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootout.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        try? bootout.run()
        bootout.waitUntilExit()
        exit(0)
    }

    func send(_ object: [String: Any], on task: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { error in if let error { log("Send failed: \(error.localizedDescription)") } }
    }

    /// Sends the status now if it changed.
    func pushStatus() async {
        guard let task = socket, task.state == .running else { return }
        let status = await Kimi.status()
        if status != lastSent {
            lastSent = status
            send(["type": "status", "status": encode(status)], on: task)
        }
    }

    /// Asks the relay to send the phones paired here an alert (relay 2026-11 and later).
    func alert(_ kind: String, version: String) {
        guard let task = socket, task.state == .running else { return }
        send(["type": "event", "kind": kind, "version": version, "computerName": Host.current().localizedName ?? "your Mac"], on: task)
    }

    func encode(_ status: KimiStatus) -> Any {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(status))) ?? [:]
    }

    func reconnect(after reason: String) {
        guard !removed, socket != nil else { return }
        lastPong = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        let delay = backoff + Double.random(in: 0...backoff / 2)
        backoff = min(backoff * 2, 300)
        log("Disconnected (\(reason)); reconnecting in \(Int(delay))s")
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }

    /// Every 20 s: a free protocol ping keeps the connection alive, and a status message goes out
    /// only when Kimi Code's Remote Control state has changed. A connection with no pong for 70 s
    /// is dead (after sleep, or a network change, a socket can look open for hours) and reopens.
    func startTimers() {
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self, let task = self.socket, task.state == .running else { return }
            if let since = self.lastPong, Date().timeIntervalSince(since) > 70 {
                self.reconnect(after: "no answer from the relay")
                return
            }
            if self.lastPong == nil { self.lastPong = Date() }
            task.sendPing { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, task === self.socket else { return }
                    if let error {
                        self.reconnect(after: "ping failed: \(error.localizedDescription)")
                    } else {
                        self.lastPong = Date()
                    }
                }
            }
            Task { await self.pushStatus() }
        }
    }
}

// MARK: - Main

if CommandLine.arguments.contains("--status") {
    let done = DispatchSemaphore(value: 0)
    Task {
        let data = (try? JSONEncoder().encode(await Kimi.status())) ?? Data("{}".utf8)
        print(String(data: data, encoding: .utf8) ?? "{}")
        done.signal()
    }
    done.wait()
    exit(0)
}

guard let config = try? JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL)) else {
    log("Missing or unreadable config at \(configURL.path)")
    exit(78) // EX_CONFIG: launchd's KeepAlive won't spin on a missing config.
}
let pairings = Array(config.pairings.prefix(8))
guard !pairings.isEmpty else {
    log("No pairing in \(configURL.path)")
    exit(78)
}
log("CodeMi Helper \(helperVersion) starting with \(pairings.count) pairing\(pairings.count == 1 ? "" : "s")")
let clients = pairings.map { RelayClient(relay: config.relay, secret: $0) }
for client in clients {
    client.connect()
    client.startTimers()
}
Watcher.onUpdateReady = { version in for client in clients { client.alert("kimiUpdate", version: version) } }
Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in Task { await Watcher.tick() } }
RunLoop.main.run()
