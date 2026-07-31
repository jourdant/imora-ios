import Foundation
import Observation
import os

nonisolated let realtimeLog = Logger(subsystem: "app.imora", category: "realtime")

/// changes broadcast to listeners. instant patches carry data; resync asks
/// models to diff their buckets against the server.
@MainActor
protocol RealtimeListener: AnyObject {
    func realtimeAssetsRemoved(_ ids: Set<String>)
    func realtimeAssetUpdated(_ detail: AssetDetail)
    func realtimeResync()
    func realtimeAlbumsChanged()
    func realtimeLocalChanged()
}

extension RealtimeListener {
    func realtimeAssetsRemoved(_ ids: Set<String>) {}
    func realtimeAssetUpdated(_ detail: AssetDetail) {}
    func realtimeResync() {}
    func realtimeAlbumsChanged() {}
    func realtimeLocalChanged() {}
}

/// keeps the app in sync with the server over the immich socket.io channel,
/// so grids update live and pull-to-refresh is never needed. models register
/// as weak listeners; screens can also observe the generation counters.
@Observable
final class RealtimeHub {
    private struct WeakListener {
        weak var value: (any RealtimeListener)?
    }

    /// bumped after album events so album lists reload without a listener.
    private(set) var albumsGeneration = 0
    private(set) var isConnected = false

    private let client: ImmichClient
    private var listeners: [WeakListener] = []
    private var active = false
    private var connectionTask: Task<Void, Never>?
    private var resyncDebounce: Task<Void, Never>?
    private var lastResyncFlush: Date = .distantPast
    private var localDebounce: Task<Void, Never>?
    private var safetyTick: Task<Void, Never>?

    /// coalescing window for bursts of server events.
    private static let resyncDelay: Duration = .milliseconds(1_500)
    /// a first event after this much quiet flushes immediately.
    private static let resyncMaxWait: TimeInterval = 5
    /// background diff while connected, catching events the server never
    /// sends. one cheap buckets request per live grid when nothing changed.
    private static let safetyInterval: Duration = .seconds(120)

    init(client: ImmichClient) {
        self.client = client
    }

    func addListener(_ listener: any RealtimeListener) {
        listeners.removeAll { $0.value == nil || $0.value === listener }
        listeners.append(WeakListener(value: listener))
    }

    // MARK: - lifecycle

    /// foreground drives connection: connect and resync on activation, tear
    /// down when the app leaves the foreground.
    func setActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        if value {
            startConnection()
            // the resync doubles as the missed-while-backgrounded catch-up.
            broadcastResyncNow()
            startSafetyTick()
        } else {
            connectionTask?.cancel()
            connectionTask = nil
            safetyTick?.cancel()
            safetyTick = nil
            resyncDebounce?.cancel()
            resyncDebounce = nil
            isConnected = false
        }
    }

    func shutdown() {
        setActive(false)
        localDebounce?.cancel()
        listeners.removeAll()
    }

    /// called by the backup manager whenever device assets or the backup
    /// index changed. debounced so upload bursts coalesce.
    func notifyLocalChange() {
        guard localDebounce == nil else { return }
        localDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, !Task.isCancelled else { return }
            self.localDebounce = nil
            self.broadcast { $0.realtimeLocalChanged() }
        }
    }

    // MARK: - broadcasting

    private func broadcast(_ action: (any RealtimeListener) -> Void) {
        listeners.removeAll { $0.value == nil }
        for listener in listeners {
            if let value = listener.value { action(value) }
        }
    }

    private func scheduleResync() {
        if Date().timeIntervalSince(lastResyncFlush) > Self.resyncMaxWait {
            broadcastResyncNow()
            return
        }
        guard resyncDebounce == nil else { return }
        resyncDebounce = Task { [weak self] in
            try? await Task.sleep(for: Self.resyncDelay)
            guard let self, !Task.isCancelled else { return }
            self.resyncDebounce = nil
            self.broadcastResyncNow()
        }
    }

    private func broadcastResyncNow() {
        lastResyncFlush = Date()
        broadcast { $0.realtimeResync() }
    }

    private func startSafetyTick() {
        safetyTick?.cancel()
        safetyTick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.safetyInterval)
                guard let self, !Task.isCancelled else { return }
                self.broadcastResyncNow()
            }
        }
    }

    // MARK: - socket connection

    private func startConnection() {
        guard connectionTask == nil else { return }
        connectionTask = Task { [weak self] in
            var backoff: Double = 1
            while let self, self.active, !Task.isCancelled {
                do {
                    try await self.connectOnce()
                    backoff = 1
                } catch is CancellationError {
                    return
                } catch {
                    realtimeLog.info("socket dropped: \(error)")
                }
                self.isConnected = false
                guard self.active, !Task.isCancelled else { return }
                let jitter = Double.random(in: 0...0.4) * backoff
                try? await Task.sleep(for: .seconds(backoff + jitter))
                backoff = min(backoff * 2, 30)
            }
        }
    }

    /// one engine.io v4 + socket.io v4 session over a websocket. returns only
    /// when the socket closes or errors.
    private func connectOnce() async throws {
        let task = SocketConnection.makeTask(apiURL: client.apiURL, headers: client.authHeaders, token: client.accessToken)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        // grace before the first server frame, then a rolling deadline based
        // on the server ping cadence so half-open sockets get torn down.
        var deadline: Duration = .seconds(15)

        while !Task.isCancelled {
            let message = try await SocketConnection.receive(from: task, timeout: deadline)
            guard case .string(let text) = message else { continue }
            switch SocketConnection.parse(text) {
            case .open(let pingInterval, let pingTimeout):
                deadline = .milliseconds(pingInterval + pingTimeout + 5_000)
                try await task.send(.string("40"))
            case .ping:
                try await task.send(.string("3"))
            case .connected:
                realtimeLog.info("socket connected")
                isConnected = true
            case .connectError(let detail):
                throw ImmichError.http(401, detail)
            case .event(let name, let payload):
                handleEvent(name, payload: payload)
            case .close:
                return
            case .ignored:
                break
            }
        }
    }

    // MARK: - events

    /// both the modern sync events and the legacy per-asset events are
    /// registered; servers emit whichever set their version supports.
    private func handleEvent(_ name: String, payload: Any?) {
        switch name {
        case "AssetUploadReadyV1", "AssetUploadReadyV2", "AssetEditReadyV1", "AssetEditReadyV2", "on_upload_success", "on_asset_restore":
            scheduleResync()

        case "on_asset_delete", "on_asset_trash", "on_asset_hidden":
            let ids = Self.assetIDs(from: payload)
            if !ids.isEmpty {
                broadcast { $0.realtimeAssetsRemoved(ids) }
            }
            scheduleResync()

        case "on_asset_update":
            if let payload,
               let data = try? JSONSerialization.data(withJSONObject: payload),
               let detail = try? JSONDecoder().decode(AssetDetail.self, from: data) {
                broadcast { $0.realtimeAssetUpdated(detail) }
            }
            scheduleResync()

        case "on_album_update":
            albumsGeneration += 1
            broadcast { $0.realtimeAlbumsChanged() }

        default:
            break
        }
    }

    /// legacy events carry a bare id, an id array, or a wrapping object.
    private static func assetIDs(from payload: Any?) -> Set<String> {
        switch payload {
        case let id as String:
            return [id]
        case let ids as [String]:
            return Set(ids)
        case let object as [String: Any]:
            for key in ["assetIds", "ids", "assetId", "id"] {
                if let ids = assetIDs(from: object[key]) as Set<String>?, !ids.isEmpty {
                    return ids
                }
            }
            return []
        default:
            return []
        }
    }
}

// MARK: - wire protocol

/// minimal engine.io v4 framing over urlsession websockets. only what the
/// immich server actually uses: text frames, websocket transport, default
/// namespace.
private nonisolated enum SocketConnection {
    enum Packet {
        case open(pingInterval: Int, pingTimeout: Int)
        case ping
        case connected
        case connectError(String)
        case event(String, Any?)
        case close
        case ignored
    }

    static func makeTask(apiURL: URL, headers: [String: String], token: String) -> URLSessionWebSocketTask {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)!
        components.scheme = apiURL.scheme == "http" ? "ws" : "wss"
        components.path = apiURL.path() + "/socket.io/"
        components.query = "EIO=4&transport=websocket"
        var request = URLRequest(url: components.url!)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // the server authenticates the handshake from the session cookie.
        request.setValue("immich_access_token=\(token)", forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 15
        return URLSession.shared.webSocketTask(with: request)
    }

    /// receive with a deadline: a healthy server pings every pinginterval, so
    /// prolonged silence means the connection is dead even if tcp disagrees.
    static func receive(
        from task: URLSessionWebSocketTask,
        timeout: Duration
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message?.self) { group in
            group.addTask { try await task.receive() }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let message = first else {
                throw URLError(.timedOut)
            }
            return message
        }
    }

    static func parse(_ text: String) -> Packet {
        guard let first = text.first else { return .ignored }
        let rest = String(text.dropFirst())
        switch first {
        case "0":
            let object = (try? JSONSerialization.jsonObject(with: Data(rest.utf8))) as? [String: Any]
            return .open(
                pingInterval: object?["pingInterval"] as? Int ?? 25_000,
                pingTimeout: object?["pingTimeout"] as? Int ?? 20_000
            )
        case "1":
            return .close
        case "2":
            return .ping
        case "4":
            return parseSocketIO(rest)
        default:
            return .ignored
        }
    }

    private static func parseSocketIO(_ body: String) -> Packet {
        guard let type = body.first else { return .ignored }
        switch type {
        case "0":
            return .connected
        case "4":
            return .connectError(String(body.dropFirst()))
        case "2":
            // event: optional namespace and ack id precede the json array.
            guard let start = body.firstIndex(of: "["),
                  let array = (try? JSONSerialization.jsonObject(with: Data(body[start...].utf8))) as? [Any],
                  let name = array.first as? String
            else { return .ignored }
            return .event(name, array.count > 1 ? array[1] : nil)
        default:
            return .ignored
        }
    }
}
