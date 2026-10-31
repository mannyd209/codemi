// CodeMi Helper for macOS.
//
// Keeps a WebSocket open to the CodeMi relay so the CodeMi iPhone app can check Kimi Code's
// Remote Control and turn it back on while Remote Control itself is off. It only ever reads the
// Remote Control status and turns Remote Control on (opening Kimi Code first if it was quit).
// It never runs any other command.
//
// Config: ~/Library/Application Support/CodeMi Helper/config.json
//   {"relay": "...", "secrets": ["...", ...], "secret": "..."}
// Each pairing (one per iPhone or iPad that installed the helper, up to 8) has its own
// connection, so installing from another device never cuts off the ones already paired, and
// removing it from one device only drops that device's pairing (the last one removes the helper).
// "secret" alone is the 0.2 format, still read.

import Foundation

let helperVersion = "0.3.1"
let home = FileManager.default.homeDirectoryForCurrentUser
let kimiHome = home.appendingPathComponent(".kimi-code")
let configURL = ProcessInfo.processInfo.environment["CODEMI_HELPER_CONFIG"].map { URL(fileURLWithPath: $0) }
    ?? home.appendingPathComponent("Library/Application Support/CodeMi Helper/config.json")

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
                send(["type": "status", "id": id, "status": encode(status)], on: task)
            case "enable":
                log("Relay asked to turn Remote Control on")
                let result = await Kimi.enable()
                log("Turn on result: ok=\(result.ok) state=\(result.status.state ?? "-") error=\(result.error ?? "-")")
                lastSent = result.status
                var reply: [String: Any] = ["type": "result", "id": id, "ok": result.ok, "status": encode(result.status)]
                if let error = result.error { reply["error"] = error }
                send(reply, on: task)
            case "uninstall":
                send(["type": "result", "id": id, "ok": true], on: task)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Self.removePairing(secret) {
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

    func encode(_ status: KimiStatus) -> Any {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(status))) ?? [:]
    }

    func reconnect(after reason: String) {
        guard !removed else { return }
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        let delay = backoff + Double.random(in: 0...backoff / 2)
        backoff = min(backoff * 2, 300)
        log("Disconnected (\(reason)); reconnecting in \(Int(delay))s")
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }

    /// Every 20 s: a free protocol ping keeps the connection alive, and a status message goes out
    /// only when Kimi Code's Remote Control state has changed.
    func startTimers() {
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self, let task = self.socket, task.state == .running else { return }
            task.sendPing { error in if let error { log("Ping failed: \(error.localizedDescription)") } }
            Task {
                let status = await Kimi.status()
                if status != self.lastSent {
                    self.lastSent = status
                    self.send(["type": "status", "status": self.encode(status)], on: task)
                }
            }
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
RunLoop.main.run()
