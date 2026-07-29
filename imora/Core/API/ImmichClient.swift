import Foundation

nonisolated enum ImmichError: LocalizedError {
    case invalidURL
    case unreachable
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "the server address is not a valid url."
        case .unreachable: "could not reach the server. check the address and your connection."
        case .http(let code, let message):
            switch code {
            case 401: "wrong email or password."
            case 403: "access denied."
            default: message.isEmpty ? "server error \(code)." : message
            }
        case .decoding(let detail): "unexpected server response: \(detail)"
        }
    }
}

/// thin async client over the immich http api.
nonisolated final class ImmichClient: Sendable {
    /// resolved api base, e.g. https://demo.immich.app/api
    let apiURL: URL
    let accessToken: String
    private let session: URLSession

    init(apiURL: URL, accessToken: String) {
        self.apiURL = apiURL
        self.accessToken = accessToken
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
        ]
        config.urlCache = nil
        self.session = URLSession(configuration: config)
    }

    var authHeaders: [String: String] { ["Authorization": "Bearer \(accessToken)"] }

    // MARK: - server resolution

    /// normalizes user input and finds the api endpoint, honoring /.well-known/immich.
    static func resolveAPIURL(from input: String) async throws -> URL {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw ImmichError.invalidURL }
        if !raw.contains("://") { raw = "https://" + raw }
        while raw.hasSuffix("/") { raw.removeLast() }
        guard var url = URL(string: raw), url.host() != nil else { throw ImmichError.invalidURL }

        let probe = URLSession(configuration: .ephemeral)
        // if the user already pointed at /api, trust it after a ping.
        if url.path().hasSuffix("/api") {
            if await ping(url, session: probe) { return url }
            throw ImmichError.unreachable
        }

        // well-known lookup lets admins host the api elsewhere.
        if let wellKnown = try? await fetchWellKnown(base: url, session: probe) {
            url = wellKnown
        } else {
            url = url.appending(path: "api")
        }
        guard await ping(url, session: probe) else { throw ImmichError.unreachable }
        return url
    }

    private static func fetchWellKnown(base: URL, session: URLSession) async throws -> URL? {
        var request = URLRequest(url: base.appending(path: ".well-known/immich"))
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let parsed = try JSONDecoder().decode(WellKnownImmich.self, from: data)
        let endpoint = parsed.api.endpoint
        if endpoint.hasPrefix("http") { return URL(string: endpoint) }
        return base.appending(path: endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private static func ping(_ apiURL: URL, session: URLSession) async -> Bool {
        var request = URLRequest(url: apiURL.appending(path: "server/ping"))
        request.timeoutInterval = 8
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: - auth

    static func login(apiURL: URL, email: String, password: String) async throws -> LoginResponse {
        var request = URLRequest(url: apiURL.appending(path: "auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("iOS", forHTTPHeaderField: "deviceType")
        request.setValue(deviceModel(), forHTTPHeaderField: "deviceModel")
        request.httpBody = try JSONEncoder().encode(LoginCredentials(email: email, password: password))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImmichError.unreachable }
        guard http.statusCode == 201 || http.statusCode == 200 else {
            throw ImmichError.http(http.statusCode, Self.serverMessage(from: data))
        }
        return try JSONDecoder().decode(LoginResponse.self, from: data)
    }

    func logout() async {
        _ = try? await send(path: "auth/logout", method: "POST") as Data
    }

    private static func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    // MARK: - core requests

    private static func serverMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = object["message"] as? String { return message }
            if let messages = object["message"] as? [String] { return messages.joined(separator: "\n") }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func send(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> Data {
        var components = URLComponents(url: apiURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImmichError.unreachable }
        guard (200..<300).contains(http.statusCode) else {
            throw ImmichError.http(http.statusCode, Self.serverMessage(from: data))
        }
        return data
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await send(path: path, query: query)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ImmichError.decoding("\(error)")
        }
    }

    private func request<T: Decodable, B: Encodable>(_ path: String, method: String, body: B) async throws -> T {
        let data = try await send(path: path, method: method, body: JSONEncoder().encode(body))
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ImmichError.decoding("\(error)")
        }
    }

    @discardableResult
    private func mutate<B: Encodable>(_ path: String, method: String, body: B?) async throws -> Data {
        try await send(path: path, method: method, body: body.map { try JSONEncoder().encode($0) })
    }

    // MARK: - users and server

    func currentUser() async throws -> CurrentUser { try await get("users/me") }
    func serverAbout() async throws -> ServerAbout { try await get("server/about") }
    func serverFeatures() async throws -> ServerFeatures { try await get("server/features") }
    func serverStorage() async throws -> ServerStorage { try await get("server/storage") }

    // MARK: - timeline

    func timeBuckets(_ filter: TimelineFilter) async throws -> [TimeBucket] {
        try await get("timeline/buckets", query: filter.queryItems)
    }

    func timeBucket(_ bucket: String, filter: TimelineFilter) async throws -> [Asset] {
        var query = filter.queryItems
        query.append(URLQueryItem(name: "timeBucket", value: bucket))
        let columnar: TimeBucketAssets = try await get("timeline/bucket", query: query)
        return columnar.assets()
    }

    // MARK: - assets

    func assetDetail(id: String) async throws -> AssetDetail { try await get("assets/\(id)") }

    func setFavorite(ids: [String], _ value: Bool) async throws {
        try await mutate("assets", method: "PUT", body: ["ids": AnyEncodable(ids), "isFavorite": AnyEncodable(value)])
    }

    func setVisibility(ids: [String], _ value: AssetVisibility) async throws {
        try await mutate("assets", method: "PUT", body: ["ids": AnyEncodable(ids), "visibility": AnyEncodable(value.rawValue)])
    }

    func trashAssets(ids: [String], force: Bool = false) async throws {
        try await mutate("assets", method: "DELETE", body: ["ids": AnyEncodable(ids), "force": AnyEncodable(force)])
    }

    func restoreAssets(ids: [String]) async throws {
        try await mutate("trash/restore/assets", method: "POST", body: ["ids": ids])
    }

    func emptyTrash() async throws { try await mutate("trash/empty", method: "POST", body: Optional<Int>.none) }
    func restoreTrash() async throws { try await mutate("trash/restore", method: "POST", body: Optional<Int>.none) }

    // MARK: - media urls

    func thumbnailURL(assetID: String, size: String = "thumbnail") -> URL {
        apiURL.appending(path: "assets/\(assetID)/thumbnail").appending(queryItems: [URLQueryItem(name: "size", value: size)])
    }

    func originalURL(assetID: String) -> URL {
        apiURL.appending(path: "assets/\(assetID)/original")
    }

    func playbackURL(assetID: String) -> URL {
        apiURL.appending(path: "assets/\(assetID)/video/playback")
    }

    func personThumbnailURL(personID: String) -> URL {
        apiURL.appending(path: "people/\(personID)/thumbnail")
    }

    func profileImageURL(userID: String) -> URL {
        apiURL.appending(path: "users/\(userID)/profile-image")
    }

    // MARK: - albums

    func albums(isShared: Bool? = nil, isOwned: Bool? = nil) async throws -> [Album] {
        var query: [URLQueryItem] = []
        if let isShared { query.append(URLQueryItem(name: "isShared", value: isShared ? "true" : "false")) }
        if let isOwned { query.append(URLQueryItem(name: "isOwned", value: isOwned ? "true" : "false")) }
        return try await get("albums", query: query)
    }

    func album(id: String) async throws -> Album { try await get("albums/\(id)") }

    func createAlbum(name: String, description: String = "", assetIds: [String] = []) async throws -> Album {
        try await request("albums", method: "POST", body: [
            "albumName": AnyEncodable(name),
            "description": AnyEncodable(description),
            "assetIds": AnyEncodable(assetIds),
        ])
    }

    func addAssets(albumID: String, ids: [String]) async throws {
        try await mutate("albums/\(albumID)/assets", method: "PUT", body: ["ids": ids])
    }

    func removeAssets(albumID: String, ids: [String]) async throws {
        try await mutate("albums/\(albumID)/assets", method: "DELETE", body: ["ids": ids])
    }

    func deleteAlbum(id: String) async throws {
        try await mutate("albums/\(id)", method: "DELETE", body: Optional<Int>.none)
    }

    func updateAlbum(id: String, name: String?, description: String?) async throws {
        var body: [String: AnyEncodable] = [:]
        if let name { body["albumName"] = AnyEncodable(name) }
        if let description { body["description"] = AnyEncodable(description) }
        try await mutate("albums/\(id)", method: "PATCH", body: body)
    }

    // MARK: - search

    func searchSmart(query: String, page: Int = 1, size: Int = 100) async throws -> SearchResponse {
        try await request("search/smart", method: "POST", body: [
            "query": AnyEncodable(query),
            "page": AnyEncodable(page),
            "size": AnyEncodable(size),
        ])
    }

    func searchMetadata(filters: [String: AnyEncodable]) async throws -> SearchResponse {
        try await request("search/metadata", method: "POST", body: filters)
    }

    func people(withHidden: Bool = false) async throws -> PeopleResponse {
        try await get("people", query: [URLQueryItem(name: "withHidden", value: withHidden ? "true" : "false")])
    }

    func person(id: String) async throws -> Person { try await get("people/\(id)") }

    func explorePlaces() async throws -> [ExploreResponse] {
        try await get("search/explore")
    }

    func updatePerson(id: String, name: String) async throws {
        try await mutate("people/\(id)", method: "PUT", body: ["name": name])
    }

    // MARK: - memories

    func memories(for date: Date) async throws -> [Memory] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return try await get("memories", query: [URLQueryItem(name: "for", value: formatter.string(from: date))])
    }
}

// MARK: - timeline filter

nonisolated struct TimelineFilter: Hashable {
    var visibility: AssetVisibility? = .timeline
    var withPartners = false
    var withStacked = false
    var isFavorite: Bool?
    var isTrashed: Bool?
    var albumId: String?
    var personId: String?
    var userId: String?
    var order: String?

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let visibility { items.append(.init(name: "visibility", value: visibility.rawValue)) }
        if withPartners { items.append(.init(name: "withPartners", value: "true")) }
        if withStacked { items.append(.init(name: "withStacked", value: "true")) }
        if let isFavorite { items.append(.init(name: "isFavorite", value: isFavorite ? "true" : "false")) }
        if let isTrashed { items.append(.init(name: "isTrashed", value: isTrashed ? "true" : "false")) }
        if let albumId { items.append(.init(name: "albumId", value: albumId)) }
        if let personId { items.append(.init(name: "personId", value: personId)) }
        if let userId { items.append(.init(name: "userId", value: userId)) }
        if let order { items.append(.init(name: "order", value: order)) }
        return items
    }
}

// MARK: - helpers

nonisolated struct AnyEncodable: Encodable {
    private let encodeClosure: @Sendable (Encoder) throws -> Void

    init<T: Encodable & Sendable>(_ value: T) {
        encodeClosure = { encoder in try value.encode(to: encoder) }
    }

    func encode(to encoder: Encoder) throws {
        try encodeClosure(encoder)
    }
}
