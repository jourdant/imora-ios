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

    // MARK: - oauth

    /// unauthenticated fetch used by the login screen to pick the sign-in method.
    static func publicFeatures(apiURL: URL) async throws -> ServerFeatures {
        try await publicGet(apiURL.appending(path: "server/features"))
    }

    static func publicConfig(apiURL: URL) async throws -> ServerConfig {
        try await publicGet(apiURL.appending(path: "server/config"))
    }

    static func oauthAuthorize(apiURL: URL, redirectUri: String, state: String, codeChallenge: String) async throws -> URL {
        var request = URLRequest(url: apiURL.appending(path: "oauth/authorize"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "redirectUri": redirectUri,
            "state": state,
            "codeChallenge": codeChallenge,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImmichError.unreachable }
        guard (200..<300).contains(http.statusCode) else {
            throw ImmichError.http(http.statusCode, serverMessage(from: data))
        }
        let parsed = try JSONDecoder().decode(OAuthAuthorizeResponse.self, from: data)
        guard let url = URL(string: parsed.url) else { throw ImmichError.decoding("bad authorize url") }
        return url
    }

    static func oauthCallback(apiURL: URL, callbackURL: String, state: String, codeVerifier: String) async throws -> LoginResponse {
        var request = URLRequest(url: apiURL.appending(path: "oauth/callback"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("iOS", forHTTPHeaderField: "deviceType")
        request.setValue(deviceModel(), forHTTPHeaderField: "deviceModel")
        request.httpBody = try JSONEncoder().encode([
            "url": callbackURL,
            "state": state,
            "codeVerifier": codeVerifier,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImmichError.unreachable }
        guard (200..<300).contains(http.statusCode) else {
            throw ImmichError.http(http.statusCode, serverMessage(from: data))
        }
        return try JSONDecoder().decode(LoginResponse.self, from: data)
    }

    private static func publicGet<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ImmichError.unreachable
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ImmichError.decoding("\(error)")
        }
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
    func preferences() async throws -> UserPreferences { try await get("users/me/preferences") }

    func updatePreference(section: String, enabled: Bool) async throws -> UserPreferences {
        try await request("users/me/preferences", method: "PUT", body: [section: ["enabled": enabled]])
    }

    func updateEmailNotifications(_ preferences: EmailNotificationPreferences) async throws -> UserPreferences {
        try await request("users/me/preferences", method: "PUT", body: ["emailNotifications": preferences])
    }
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

    /// partial update of one asset. only provided fields are sent, so a nil
    /// leaves the server value untouched.
    @discardableResult
    func updateAsset(
        id: String,
        description: String? = nil,
        dateTimeOriginal: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        rating: Int? = nil
    ) async throws -> AssetDetail {
        var body: [String: AnyEncodable] = [:]
        if let description { body["description"] = AnyEncodable(description) }
        if let dateTimeOriginal { body["dateTimeOriginal"] = AnyEncodable(dateTimeOriginal) }
        if let latitude { body["latitude"] = AnyEncodable(latitude) }
        if let longitude { body["longitude"] = AnyEncodable(longitude) }
        if let rating { body["rating"] = AnyEncodable(rating) }
        return try await request("assets/\(id)", method: "PUT", body: body)
    }

    func setFavorite(ids: [String], _ value: Bool) async throws {
        try await mutate("assets", method: "PUT", body: ["ids": AnyEncodable(ids), "isFavorite": AnyEncodable(value)])
    }

    // MARK: - asset edits, server-side non-destructive since v2.6

    func assetEdits(id: String) async throws -> [AssetEdit] {
        struct Envelope: Decodable { let edits: [AssetEdit] }
        let data = try await send(path: "assets/\(id)/edits")
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).edits
        } catch {
            throw ImmichError.decoding("\(error)")
        }
    }

    /// replaces the asset's whole edit list; the server re-renders derivatives.
    func applyEdits(id: String, edits: [AssetEdit]) async throws {
        try await mutate("assets/\(id)/edits", method: "PUT", body: ["edits": edits])
    }

    func clearEdits(id: String) async throws {
        try await mutate("assets/\(id)/edits", method: "DELETE", body: Optional<Int>.none)
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

    /// edited defaults to true so renders reflect server-side edits; pass
    /// false to fetch the untouched picture, e.g. inside the editor.
    /// cacheKey is the thumbhash, the official cache-buster: it changes when
    /// derivatives are re-rendered, so edits invalidate stale cached thumbs.
    func thumbnailURL(assetID: String, size: String = "thumbnail", edited: Bool = true, cacheKey: String? = nil) -> URL {
        var query = [
            URLQueryItem(name: "size", value: size),
            URLQueryItem(name: "edited", value: edited ? "true" : "false"),
        ]
        if let cacheKey, !cacheKey.isEmpty {
            query.append(URLQueryItem(name: "c", value: cacheKey))
        }
        return apiURL.appending(path: "assets/\(assetID)/thumbnail").appending(queryItems: query)
    }

    /// raw original bytes. no edited param: backup dedup and download both
    /// verify checksums computed over these exact bytes.
    func originalURL(assetID: String) -> URL {
        apiURL.appending(path: "assets/\(assetID)/original")
    }

    /// original with server-side edits applied when there are any; the right
    /// choice for share and open-style features.
    func editedOriginalURL(assetID: String) -> URL {
        apiURL.appending(path: "assets/\(assetID)/original").appending(queryItems: [
            URLQueryItem(name: "edited", value: "true"),
        ])
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

    func albums(isShared: Bool? = nil, isOwned: Bool? = nil, assetID: String? = nil) async throws -> [Album] {
        var query: [URLQueryItem] = []
        if let isShared { query.append(URLQueryItem(name: "isShared", value: isShared ? "true" : "false")) }
        if let isOwned { query.append(URLQueryItem(name: "isOwned", value: isOwned ? "true" : "false")) }
        if let assetID { query.append(URLQueryItem(name: "assetId", value: assetID)) }
        return try await get("albums", query: query)
    }

    func album(id: String) async throws -> Album { try await get("albums/\(id)") }

    /// ids of everything already in the album. AlbumResponseDto carries no
    /// asset list - verified against v3.1 - and walking the album's time
    /// buckets costs one request per month, which is how the web client pays
    /// for it lazily. a metadata search scoped to the album answers a thousand
    /// at a time instead, and only the ids are decoded.
    func albumAssetIDs(id: String) async throws -> Set<String> {
        struct Page: Decodable {
            struct Assets: Decodable {
                struct Item: Decodable { let id: String }
                let items: [Item]
                let nextPage: String?
            }
            let assets: Assets
        }

        var ids: Set<String> = []
        var page = 1
        while true {
            try Task.checkCancellation()
            let body: [String: AnyEncodable] = [
                "albumIds": AnyEncodable([id]),
                "size": AnyEncodable(1_000),
                "page": AnyEncodable(page),
            ]
            let result: Page = try await request("search/metadata", method: "POST", body: body)
            ids.formUnion(result.assets.items.map(\.id))
            guard result.assets.nextPage != nil else { return ids }
            page += 1
        }
    }

    func createAlbum(name: String, description: String = "", assetIds: [String] = []) async throws -> Album {
        try await request("albums", method: "POST", body: [
            "albumName": AnyEncodable(name),
            "description": AnyEncodable(description),
            "assetIds": AnyEncodable(assetIds),
        ])
    }

    @discardableResult
    func addAssets(albumID: String, ids: [String]) async throws -> [BulkIdResult] {
        try await request("albums/\(albumID)/assets", method: "PUT", body: ["ids": ids])
    }

    @discardableResult
    func removeAssets(albumID: String, ids: [String]) async throws -> [BulkIdResult] {
        try await request("albums/\(albumID)/assets", method: "DELETE", body: ["ids": ids])
    }

    func deleteAlbum(id: String) async throws {
        try await mutate("albums/\(id)", method: "DELETE", body: Optional<Int>.none)
    }

    func updateAlbum(
        id: String,
        name: String? = nil,
        description: String? = nil,
        thumbnailAssetId: String? = nil,
        isActivityEnabled: Bool? = nil,
        order: String? = nil
    ) async throws {
        var body: [String: AnyEncodable] = [:]
        if let name { body["albumName"] = AnyEncodable(name) }
        if let description { body["description"] = AnyEncodable(description) }
        if let thumbnailAssetId { body["albumThumbnailAssetId"] = AnyEncodable(thumbnailAssetId) }
        if let isActivityEnabled { body["isActivityEnabled"] = AnyEncodable(isActivityEnabled) }
        if let order { body["order"] = AnyEncodable(order) }
        try await mutate("albums/\(id)", method: "PATCH", body: body)
    }

    /// invites users; the server defaults their role to editor, same as the
    /// official mobile client.
    func addAlbumUsers(albumID: String, userIDs: [String]) async throws {
        let users = userIDs.map { ["userId": $0] }
        try await mutate("albums/\(albumID)/users", method: "PUT", body: ["albumUsers": users])
    }

    func updateAlbumUserRole(albumID: String, userID: String, role: String) async throws {
        try await mutate("albums/\(albumID)/user/\(userID)", method: "PUT", body: ["role": role])
    }

    /// removes a shared user; passing your own id leaves the album.
    func removeAlbumUser(albumID: String, userID: String) async throws {
        try await mutate("albums/\(albumID)/user/\(userID)", method: "DELETE", body: Optional<Int>.none)
    }

    /// every visible server user, used by the invite picker.
    func allUsers() async throws -> [User] { try await get("users") }

    /// uploads a new profile image for the current user.
    func setProfileImage(data: Data, filename: String, mimeType: String) async throws {
        let boundary = "imora-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: apiURL.appending(path: "users/profile-image"))
        request.httpMethod = "POST"
        request.setValue(MultipartBody.contentType(boundary: boundary), forHTTPHeaderField: "Content-Type")
        let (respData, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else { throw ImmichError.unreachable }
        guard (200..<300).contains(http.statusCode) else {
            throw ImmichError.http(http.statusCode, Self.serverMessage(from: respData))
        }
    }


    // MARK: - shared links

    func sharedLinks(albumID: String? = nil) async throws -> [SharedLink] {
        var query: [URLQueryItem] = []
        if let albumID { query.append(URLQueryItem(name: "albumId", value: albumID)) }
        return try await get("shared-links", query: query)
    }

    func createSharedLink(albumID: String, options: SharedLinkOptions) async throws -> SharedLink {
        var body = options.bodyFields(explicitNulls: false)
        body["type"] = AnyEncodable("ALBUM")
        body["albumId"] = AnyEncodable(albumID)
        return try await request("shared-links", method: "POST", body: body)
    }

    /// public link for a hand-picked set of assets, type INDIVIDUAL.
    func createSharedLink(assetIDs: [String], options: SharedLinkOptions) async throws -> SharedLink {
        var body = options.bodyFields(explicitNulls: false)
        body["type"] = AnyEncodable("INDIVIDUAL")
        body["assetIds"] = AnyEncodable(assetIDs)
        return try await request("shared-links", method: "POST", body: body)
    }

    func updateSharedLink(id: String, options: SharedLinkOptions) async throws -> SharedLink {
        try await request("shared-links/\(id)", method: "PATCH", body: options.bodyFields(explicitNulls: true))
    }

    func deleteSharedLink(id: String) async throws {
        try await mutate("shared-links/\(id)", method: "DELETE", body: Optional<Int>.none)
    }

    /// base for public share urls: the external domain when the admin set one,
    /// else the api url with its /api suffix stripped.
    func serverWebURL() async -> URL {
        if let config = try? await Self.publicConfig(apiURL: apiURL),
           let domain = config.externalDomain, !domain.isEmpty,
           let url = URL(string: domain), url.host() != nil {
            return url
        }
        if apiURL.lastPathComponent == "api" {
            return apiURL.deletingLastPathComponent()
        }
        return apiURL
    }

    // MARK: - search

    /// routes to /search/smart when a context query is set, /search/metadata
    /// otherwise, mirroring the official mobile client.
    func search(_ filter: SearchFilter, page: Int) async throws -> SearchResponse {
        let path = filter.usesSmartSearch ? "search/smart" : "search/metadata"
        return try await request(path, method: "POST", body: filter.requestBody(page: page))
    }

    func searchMetadata(filters: [String: AnyEncodable]) async throws -> SearchResponse {
        try await request("search/metadata", method: "POST", body: filters)
    }

    /// distinct exif values for the filter dropdowns. types: country, state,
    /// city, camera-make, camera-model. narrowing params cascade the way the
    /// pickers do.
    func searchSuggestions(type: String, country: String? = nil, state: String? = nil, make: String? = nil) async throws -> [String] {
        var query = [URLQueryItem(name: "type", value: type)]
        if let country { query.append(URLQueryItem(name: "country", value: country)) }
        if let state { query.append(URLQueryItem(name: "state", value: state)) }
        if let make { query.append(URLQueryItem(name: "make", value: make)) }
        let values: [String?] = try await get("search/suggestions", query: query)
        return values.compactMap(\.self).filter { !$0.isEmpty }
    }

    func tags() async throws -> [Tag] { try await get("tags") }

    func people(withHidden: Bool = false) async throws -> PeopleResponse {
        try await get("people", query: [URLQueryItem(name: "withHidden", value: withHidden ? "true" : "false")])
    }

    func person(id: String) async throws -> Person { try await get("people/\(id)") }

    func explorePlaces() async throws -> [ExploreResponse] {
        try await get("search/explore")
    }

    /// one representative asset per city, alphabetical.
    func cities() async throws -> [AssetDetail] {
        try await get("search/cities")
    }

    func updatePerson(id: String, name: String) async throws {
        try await mutate("people/\(id)", method: "PUT", body: ["name": name])
    }

    // MARK: - map

    /// every geotagged asset the filter allows, one point each. the server has
    /// no bounds parameter here - official clients fetch the whole set once and
    /// cluster it client side.
    func mapMarkers(_ options: MapMarkerOptions) async throws -> [MapMarker] {
        try await get("map/markers", query: options.queryItems)
    }

    // MARK: - notifications

    /// the whole inbox, newest first. immich has no push transport, so this and
    /// the on_notification socket event are the only ways an entry surfaces.
    func notifications(unreadOnly: Bool = false) async throws -> [ServerNotification] {
        var query: [URLQueryItem] = []
        if unreadOnly { query.append(URLQueryItem(name: "unread", value: "true")) }
        let items: [ServerNotification] = try await get("notifications", query: query)
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    func markNotificationRead(id: String, at date: Date = Date()) async throws {
        try await mutate("notifications/\(id)", method: "PUT", body: ["readAt": APIDate.string(from: date)])
    }

    func markNotificationsRead(ids: [String], at date: Date = Date()) async throws {
        guard !ids.isEmpty else { return }
        try await mutate("notifications", method: "PUT", body: [
            "ids": AnyEncodable(ids),
            "readAt": AnyEncodable(APIDate.string(from: date)),
        ])
    }

    func deleteNotifications(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await mutate("notifications", method: "DELETE", body: ["ids": ids])
    }

    // MARK: - memories

    func memories(for date: Date) async throws -> [Memory] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return try await get("memories", query: [URLQueryItem(name: "for", value: formatter.string(from: date))])
    }

    // MARK: - backup

    /// downloads an asset's original file into `directory` and returns its url.
    /// the caller owns the returned file. the extension matters: photokit
    /// infers the resource type from it when importing.
    func downloadOriginal(assetID: String, to directory: URL, fileExtension: String) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (tempURL, response) = try await session.download(from: originalURL(assetID: assetID))
        guard let http = response as? HTTPURLResponse else { throw ImmichError.unreachable }
        guard (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ImmichError.http(http.statusCode, "")
        }
        var destination = directory.appending(path: "download-\(UUID().uuidString)")
        if !fileExtension.isEmpty {
            destination = destination.appendingPathExtension(fileExtension)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    /// asks the server which checksums it already stores. only a
    /// reject/duplicate result with an asset id proves the bytes exist.
    func bulkUploadCheck(_ items: [BulkUploadCheckItem]) async throws -> [BulkUploadCheckResult] {
        struct Envelope: Decodable { let results: [BulkUploadCheckResult] }
        let body = try JSONEncoder().encode(["assets": items])
        let data = try await send(path: "assets/bulk-upload-check", method: "POST", body: body)
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).results
        } catch {
            throw ImmichError.decoding("\(error)")
        }
    }

    /// multipart upload of one asset file, handed to the background session so
    /// the transfer survives the app being suspended. takes ownership of the
    /// source file: it is deleted as soon as the request body is built, so peak
    /// disk usage stays near one file size. onProgress receives the sent
    /// fraction, and `account` routes a completion that outlives this process.
    func uploadAsset(
        _ upload: AssetUploadRequest,
        account: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AssetUploadResult {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var fields: [(name: String, value: String)] = [
            ("deviceAssetId", upload.deviceAssetId),
            ("deviceId", upload.deviceId),
            ("fileCreatedAt", iso.string(from: upload.fileCreatedAt)),
            ("fileModifiedAt", iso.string(from: upload.fileModifiedAt)),
            ("isFavorite", upload.isFavorite ? "true" : "false"),
            ("duration", String(upload.durationMs)),
        ]
        if let livePhotoVideoId = upload.livePhotoVideoId {
            fields.append(("livePhotoVideoId", livePhotoVideoId))
        }
        if upload.hidden {
            fields.append(("visibility", "hidden"))
        }

        let boundary = "imora-\(UUID().uuidString)"
        // the body outlives this process when the app is suspended mid-transfer,
        // so it cannot live in a directory the system may reclaim.
        let bodyURL = try MultipartBody.makeBodyFile(
            fields: fields,
            fileField: "assetData",
            filename: upload.filename,
            contentsOf: upload.fileURL,
            boundary: boundary,
            in: BackgroundUploader.bodyDirectory
        )
        try? FileManager.default.removeItem(at: upload.fileURL)

        var request = URLRequest(url: apiURL.appending(path: "assets"))
        request.httpMethod = "POST"
        request.setValue(MultipartBody.contentType(boundary: boundary), forHTTPHeaderField: "Content-Type")
        request.setValue(upload.checksum, forHTTPHeaderField: "x-immich-checksum")
        // the background session carries none of this client's session headers.
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let ticket = BackgroundUploader.Ticket(
            account: account,
            localId: upload.deviceAssetId,
            isMotion: upload.isMotion,
            bodyPath: bodyURL.path
        )
        let data = try await BackgroundUploader.shared.upload(
            request,
            fromFile: bodyURL,
            ticket: ticket,
            onProgress: onProgress
        )
        do {
            return try JSONDecoder().decode(AssetUploadResult.self, from: data)
        } catch {
            throw ImmichError.decoding("\(error)")
        }
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
    /// takenAt (default) or createdAt for upload-time ordering.
    var orderBy: String?
    /// "west,south,east,north" - restricts the buckets to a map area.
    var bbox: String?

    /// recently-added screens bucket and group by upload time.
    var groupsByUploadDate: Bool { orderBy == "createdAt" }

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let bbox { items.append(.init(name: "bbox", value: bbox)) }
        if let visibility { items.append(.init(name: "visibility", value: visibility.rawValue)) }
        if withPartners { items.append(.init(name: "withPartners", value: "true")) }
        if withStacked { items.append(.init(name: "withStacked", value: "true")) }
        if let isFavorite { items.append(.init(name: "isFavorite", value: isFavorite ? "true" : "false")) }
        if let isTrashed { items.append(.init(name: "isTrashed", value: isTrashed ? "true" : "false")) }
        if let albumId { items.append(.init(name: "albumId", value: albumId)) }
        if let personId { items.append(.init(name: "personId", value: personId)) }
        if let userId { items.append(.init(name: "userId", value: userId)) }
        if let order { items.append(.init(name: "order", value: order)) }
        if let orderBy { items.append(.init(name: "orderBy", value: orderBy)) }
        return items
    }
}

// MARK: - map marker options

/// query side of GET /map/markers. flags are only sent when true, matching the
/// official web client - the server treats a missing flag as "no".
nonisolated struct MapMarkerOptions: Hashable, Sendable {
    var isFavorite = false
    var isArchived = false
    var withPartners = false
    var withSharedAlbums = false
    var createdAfter: Date?
    var createdBefore: Date?

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if isFavorite { items.append(.init(name: "isFavorite", value: "true")) }
        if isArchived { items.append(.init(name: "isArchived", value: "true")) }
        if withPartners { items.append(.init(name: "withPartners", value: "true")) }
        if withSharedAlbums { items.append(.init(name: "withSharedAlbums", value: "true")) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let createdAfter { items.append(.init(name: "fileCreatedAfter", value: iso.string(from: createdAfter))) }
        if let createdBefore { items.append(.init(name: "fileCreatedBefore", value: iso.string(from: createdBefore))) }
        return items
    }
}

// MARK: - backup dtos

nonisolated struct BulkUploadCheckItem: Encodable, Sendable {
    let id: String
    let checksum: String
}

nonisolated struct BulkUploadCheckResult: Decodable, Sendable {
    let id: String
    let action: String
    let reason: String?
    let assetId: String?
    let isTrashed: Bool?

    /// the only combination that proves the server stores these bytes.
    var isConfirmedDuplicate: Bool {
        action == "reject" && reason == "duplicate" && assetId != nil
    }

    var isUnsupported: Bool {
        action == "reject" && reason == "unsupported-format"
    }
}

nonisolated struct AssetUploadRequest: Sendable {
    var fileURL: URL
    var checksum: String
    var filename: String
    var deviceAssetId: String
    var deviceId: String
    var fileCreatedAt: Date
    var fileModifiedAt: Date
    var isFavorite: Bool
    var durationMs: Int
    var livePhotoVideoId: String?
    /// hides the motion part of a live photo from the timeline.
    var hidden = false
    /// which half of a live photo this is, so a completion that outlives the
    /// app lands on the right side of the index entry.
    var isMotion = false
}

nonisolated struct AssetUploadResult: Decodable, Sendable {
    let id: String
    /// created, replaced or duplicate today - kept as a string so new
    /// server statuses stay a success instead of a decoding failure.
    let status: String

    var isDuplicate: Bool { status == "duplicate" }
}

// MARK: - shared link options

/// editable fields of a shared link. create omits empty optionals, edit sends
/// explicit nulls so clearing a password or expiry sticks.
nonisolated struct SharedLinkOptions: Sendable {
    var description = ""
    var password = ""
    var slug = ""
    var showMetadata = true
    var allowDownload = true
    var allowUpload = false
    var expiresAt: Date?

    init() {}

    init(from link: SharedLink) {
        description = link.description ?? ""
        password = link.password ?? ""
        slug = link.slug ?? ""
        showMetadata = link.showMetadata
        allowDownload = link.allowDownload
        allowUpload = link.allowUpload
        expiresAt = link.expiryDate
    }

    func bodyFields(explicitNulls: Bool) -> [String: AnyEncodable] {
        var fields: [String: AnyEncodable] = [
            "showMetadata": AnyEncodable(showMetadata),
            "allowDownload": AnyEncodable(allowDownload),
            "allowUpload": AnyEncodable(allowUpload),
        ]
        for (key, value) in [("description", description), ("password", password), ("slug", slug)] {
            if !value.isEmpty {
                fields[key] = AnyEncodable(value)
            } else if explicitNulls {
                fields[key] = AnyEncodable(Optional<String>.none)
            }
        }
        if let expiresAt {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            fields["expiresAt"] = AnyEncodable(iso.string(from: expiresAt))
        } else if explicitNulls {
            fields["expiresAt"] = AnyEncodable(Optional<String>.none)
        }
        return fields
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
