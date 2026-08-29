import Foundation

// MARK: - date parsing

/// the api mixes iso8601 with zone, without zone, and with variable fraction digits.
nonisolated enum APIDate {
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso = ISO8601DateFormatter()

    private static let naive: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func parse(_ raw: String) -> Date? {
        if let date = isoFractional.date(from: raw) ?? iso.date(from: raw) {
            return date
        }
        // no timezone designator: treat as utc wall clock, drop the fraction.
        return naive.date(from: String(raw.prefix(19)))
    }

    /// what the api expects back, matching javascript's toISOString.
    static func string(from date: Date) -> String {
        isoFractional.string(from: date)
    }
}

extension Date.FormatStyle {
    /// asset dates are utc wall-clock values already shifted to local time; render them without zone conversion.
    nonisolated func utc() -> Date.FormatStyle {
        var copy = self
        copy.timeZone = TimeZone(identifier: "UTC")!
        return copy
    }
}

// MARK: - auth

nonisolated struct LoginCredentials: Codable {
    let email: String
    let password: String
}

nonisolated struct LoginResponse: Codable {
    let accessToken: String
    let userId: String
    let userEmail: String
    let name: String
    let isAdmin: Bool
    let profileImagePath: String
    let shouldChangePassword: Bool
}

nonisolated struct WellKnownImmich: Codable {
    struct API: Codable { let endpoint: String }
    let api: API
}

// MARK: - user

nonisolated struct User: Codable, Identifiable, Hashable {
    let id: String
    let email: String
    let name: String
    let profileImagePath: String?
    let avatarColor: String?
}

nonisolated struct CurrentUser: Codable, Identifiable {
    let id: String
    let email: String
    let name: String
    let profileImagePath: String?
    let avatarColor: String?
    let isAdmin: Bool
    let quotaSizeInBytes: Int64?
    let quotaUsageInBytes: Int64?
    let storageLabel: String?
}

// MARK: - server

nonisolated struct ServerAbout: Codable {
    let version: String
    let versionUrl: String?
    let licensed: Bool?
    let build: String?
    let sourceRef: String?
    let sourceCommit: String?
    let nodejs: String?
}

nonisolated struct ServerFeatures: Codable {
    let smartSearch: Bool
    let facialRecognition: Bool
    let map: Bool
    let trash: Bool
    let oauth: Bool
    let oauthAutoLaunch: Bool
    let passwordLogin: Bool
    /// text recognition search, added server-side in v2.x.
    let ocr: Bool?
}

nonisolated struct ServerConfig: Codable {
    let oauthButtonText: String?
    let loginPageMessage: String?
    let externalDomain: String?
}

nonisolated struct OAuthAuthorizeResponse: Codable {
    let url: String
}

// MARK: - user preferences

nonisolated struct FeatureToggle: Codable, Hashable {
    let enabled: Bool
}

/// server-side email delivery switches. the album flags only matter while
/// `enabled` is on, which is how the web client gates them too.
nonisolated struct EmailNotificationPreferences: Codable, Hashable {
    var enabled: Bool
    var albumInvite: Bool
    var albumUpdate: Bool

    static let `default` = EmailNotificationPreferences(enabled: true, albumInvite: true, albumUpdate: true)
}

nonisolated struct UserPreferences: Codable, Hashable {
    let memories: FeatureToggle?
    let people: FeatureToggle?
    let folders: FeatureToggle?
    let ratings: FeatureToggle?
    let tags: FeatureToggle?
    let sharedLinks: FeatureToggle?
    let emailNotifications: EmailNotificationPreferences?

    var memoriesEnabled: Bool { memories?.enabled ?? true }
    var peopleEnabled: Bool { people?.enabled ?? true }
    var tagsEnabled: Bool { tags?.enabled ?? true }
    var ratingsEnabled: Bool { ratings?.enabled ?? false }
    var email: EmailNotificationPreferences { emailNotifications ?? .default }
}

nonisolated struct ServerStorage: Codable {
    let diskAvailable: String
    let diskSize: String
    let diskUse: String
    let diskUsagePercentage: Double
}

// MARK: - assets

nonisolated enum AssetType: String, Codable {
    case image = "IMAGE"
    case video = "VIDEO"
    case audio = "AUDIO"
    case other = "OTHER"
}

nonisolated enum AssetVisibility: String, Codable, Sendable {
    case timeline
    case hidden
    case archive
    case locked
}

/// lightweight asset used across grids. built from timeline buckets or full
/// dtos. codable so fetched buckets can persist for offline browsing.
nonisolated struct Asset: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let ownerId: String
    let isImage: Bool
    var isFavorite: Bool
    var isTrashed: Bool
    var visibility: AssetVisibility
    var thumbhash: String?
    var fileCreatedAt: Date
    var localOffsetHours: Double
    /// milliseconds, nil for stills.
    let duration: Int?
    let livePhotoVideoId: String?
    var ratio: Double
    let city: String?
    let country: String?
    /// server upload time, drives the recently-added ordering.
    var createdAt: Date?
    /// set for device-only assets merged into the timeline before backup.
    var localIdentifier: String? = nil
    /// snapshot of the backup index at merge time: true once every component
    /// of the device asset is confirmed on the server.
    var isLocalBackedUp = false
    /// device live photo whose motion half lives in photokit. the server pairs
    /// its two assets through `livePhotoVideoId`, but a device-only asset has
    /// no server ids yet and would otherwise look like a plain still.
    var hasLocalMotion = false
    /// carried opportunistically by full asset responses. timeline buckets
    /// omit these so opening a large share never waits on detail requests.
    var originalFileName: String? = nil
    var originalMimeType: String? = nil
    var isEdited: Bool? = nil

    var isLocal: Bool { localIdentifier != nil }

    var isVideo: Bool { !isImage }

    /// a still with a motion half, from either source.
    var isLivePhoto: Bool { isImage && (livePhotoVideoId != nil || hasLocalMotion) }

    /// date shifted into the asset's local timezone for grouping and display.
    var localDate: Date { fileCreatedAt.addingTimeInterval(localOffsetHours * 3600) }

    /// upload time shifted into device-local wall clock, comparable in the
    /// same utc calendar space the grouping code uses.
    var uploadLocalDate: Date {
        (createdAt ?? fileCreatedAt).addingTimeInterval(TimeInterval(TimeZone.current.secondsFromGMT()))
    }

    var durationLabel: String? {
        guard let duration, isVideo else { return nil }
        let total = duration / 1000
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

/// columnar response from /timeline/bucket.
nonisolated struct TimeBucketAssets: Codable {
    let id: [String]
    let ownerId: [String]
    let isImage: [Bool]
    let isFavorite: [Bool]
    let isTrashed: [Bool]
    let visibility: [AssetVisibility]?
    let thumbhash: [String?]
    let fileCreatedAt: [String]
    let localOffsetHours: [Double]
    let duration: [Int?]
    let livePhotoVideoId: [String?]
    let ratio: [Double]
    let city: [String?]?
    let country: [String?]?
    let createdAt: [String]?

    func assets() -> [Asset] {
        id.indices.map { i in
            let date = APIDate.parse(fileCreatedAt[i]) ?? .distantPast
            return Asset(
                id: id[i],
                ownerId: ownerId[i],
                isImage: isImage[i],
                isFavorite: isFavorite[i],
                isTrashed: isTrashed[i],
                visibility: visibility?[i] ?? .timeline,
                thumbhash: thumbhash[i],
                fileCreatedAt: date,
                localOffsetHours: localOffsetHours[i],
                duration: duration[i],
                livePhotoVideoId: livePhotoVideoId[i],
                ratio: ratio[i],
                city: city?[i] ?? nil,
                country: country?[i] ?? nil,
                createdAt: createdAt.flatMap { APIDate.parse($0[i]) }
            )
        }
    }
}

nonisolated struct TimeBucket: Codable, Identifiable, Hashable {
    let timeBucket: String
    let count: Int
    var id: String { timeBucket }
}

// MARK: - full asset dto, used by viewer details and search results

nonisolated struct ExifInfo: Codable, Hashable {
    let make: String?
    let model: String?
    let exifImageWidth: Double?
    let exifImageHeight: Double?
    let fileSizeInByte: Int64?
    let lensModel: String?
    let fNumber: Double?
    let focalLength: Double?
    let iso: Double?
    let exposureTime: String?
    let latitude: Double?
    let longitude: Double?
    let city: String?
    let state: String?
    let country: String?
    let dateTimeOriginal: String?
    let timeZone: String?
    let description: String?
    let rating: Double?
}

nonisolated struct AssetDetail: Codable, Identifiable, Hashable {
    let id: String
    let ownerId: String
    let type: AssetType
    let originalFileName: String
    let originalMimeType: String?
    let thumbhash: String?
    let fileCreatedAt: String
    let localDateTime: String
    /// server upload time.
    let createdAt: String?
    let isFavorite: Bool
    let isArchived: Bool?
    let isTrashed: Bool
    let visibility: AssetVisibility?
    let width: Int?
    let height: Int?
    /// milliseconds, nil for stills.
    let duration: Int?
    let exifInfo: ExifInfo?
    let livePhotoVideoId: String?
    let people: [Person]?
    let tags: [Tag]?
    let checksum: String?
    /// true once the asset has server-side edits applied.
    let isEdited: Bool?

    func asAsset() -> Asset {
        let local = APIDate.parse(localDateTime) ?? .distantPast
        let created = APIDate.parse(fileCreatedAt) ?? .distantPast
        let ratio: Double
        if let w = width, let h = height, w > 0, h > 0 {
            ratio = Double(w) / Double(h)
        } else if let w = exifInfo?.exifImageWidth, let h = exifInfo?.exifImageHeight, w > 0, h > 0 {
            ratio = w / h
        } else {
            ratio = 1
        }
        return Asset(
            id: id,
            ownerId: ownerId,
            isImage: type == .image,
            isFavorite: isFavorite,
            isTrashed: isTrashed,
            visibility: visibility ?? (isArchived == true ? .archive : .timeline),
            thumbhash: thumbhash,
            fileCreatedAt: created,
            localOffsetHours: local.timeIntervalSince(created) / 3600,
            duration: duration,
            livePhotoVideoId: livePhotoVideoId,
            ratio: ratio,
            city: exifInfo?.city,
            country: exifInfo?.country,
            createdAt: createdAt.flatMap { APIDate.parse($0) },
            originalFileName: originalFileName,
            originalMimeType: originalMimeType,
            isEdited: isEdited
        )
    }
}

// MARK: - asset edits

/// one step of the server-side non-destructive edit list. crop coordinates
/// are pixels in the original, orientation-corrected image.
nonisolated enum AssetEdit: Codable, Equatable, Sendable {
    case crop(x: Int, y: Int, width: Int, height: Int)
    case mirror(axis: String)
    case rotate(angle: Double)

    private enum CodingKeys: String, CodingKey { case action, parameters }
    private enum ParameterKeys: String, CodingKey { case x, y, width, height, axis, angle }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let action = try container.decode(String.self, forKey: .action)
        let parameters = try container.nestedContainer(keyedBy: ParameterKeys.self, forKey: .parameters)
        switch action {
        case "crop":
            self = .crop(
                x: try parameters.decode(Int.self, forKey: .x),
                y: try parameters.decode(Int.self, forKey: .y),
                width: try parameters.decode(Int.self, forKey: .width),
                height: try parameters.decode(Int.self, forKey: .height)
            )
        case "mirror":
            self = .mirror(axis: try parameters.decode(String.self, forKey: .axis))
        case "rotate":
            self = .rotate(angle: try parameters.decode(Double.self, forKey: .angle))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .action,
                in: container,
                debugDescription: "unknown edit action \(action)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var parameters = container.nestedContainer(keyedBy: ParameterKeys.self, forKey: .parameters)
        switch self {
        case .crop(let x, let y, let width, let height):
            try container.encode("crop", forKey: .action)
            try parameters.encode(x, forKey: .x)
            try parameters.encode(y, forKey: .y)
            try parameters.encode(width, forKey: .width)
            try parameters.encode(height, forKey: .height)
        case .mirror(let axis):
            try container.encode("mirror", forKey: .action)
            try parameters.encode(axis, forKey: .axis)
        case .rotate(let angle):
            try container.encode("rotate", forKey: .action)
            try parameters.encode(angle, forKey: .angle)
        }
    }
}

// MARK: - albums

nonisolated struct AlbumUser: Codable, Hashable {
    let role: String
    let user: User
}

nonisolated struct Album: Codable, Identifiable, Hashable {
    let id: String
    let albumName: String
    let description: String
    let albumThumbnailAssetId: String?
    let assetCount: Int
    let albumUsers: [AlbumUser]
    let shared: Bool
    let hasSharedLink: Bool
    let isActivityEnabled: Bool?
    let createdAt: String
    let updatedAt: String
    let startDate: String?
    let endDate: String?
    let order: String?

    /// spec guarantees the first album user is the owner.
    var owner: User? {
        albumUsers.first { $0.role == "owner" }?.user ?? albumUsers.first?.user
    }

    /// everyone except the owner, i.e. the people the album is shared with.
    var sharedUsers: [AlbumUser] {
        albumUsers.filter { $0.role != "owner" }
    }

    func role(of userID: String?) -> String? {
        guard let userID else { return nil }
        return albumUsers.first { $0.user.id == userID }?.role
    }
}

/// per-item result of album asset add and remove calls.
nonisolated struct BulkIdResult: Decodable {
    let id: String
    let success: Bool
    /// duplicate, no_permission, not_found, unknown or validation.
    let error: String?
}

// MARK: - shared links

nonisolated struct SharedLink: Codable, Identifiable, Hashable {
    let id: String
    let key: String
    let slug: String?
    let type: String
    let description: String?
    let password: String?
    let expiresAt: String?
    let allowUpload: Bool
    let allowDownload: Bool
    let showMetadata: Bool
    let createdAt: String
    /// populated for INDIVIDUAL links; used to find links containing an asset.
    let assets: [AssetDetail]?

    /// public path relative to the server web root.
    var sharePath: String {
        if let slug, !slug.isEmpty { return "s/\(slug)" }
        return "share/\(key)"
    }

    var expiryDate: Date? { expiresAt.flatMap { APIDate.parse($0) } }

    var isExpired: Bool {
        guard let expiryDate else { return false }
        return expiryDate < Date()
    }
}

// MARK: - people and search

nonisolated struct Person: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    let thumbnailPath: String?
    var isHidden: Bool?
    /// date-only string, "yyyy-MM-dd".
    var birthDate: String?
    var isFavorite: Bool?
    /// last server-side edit. the portrait url is stable for life, so this is
    /// what busts it after a featured photo changed - on any device, which is
    /// why it has to ride along with the person rather than be observed live.
    var updatedAt: String?
}

nonisolated struct Tag: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    /// full hierarchical path, e.g. "travel/asia".
    let value: String
    let parentId: String?
}

nonisolated struct PeopleResponse: Codable {
    let people: [Person]
    let total: Int
    let hidden: Int?
    let hasNextPage: Bool?
}

nonisolated struct PersonStatistics: Codable {
    let assets: Int
}

/// one detected or manual face region on an asset. person stays nil while
/// the face is unassigned.
nonisolated struct AssetFace: Codable, Identifiable, Hashable {
    let id: String
    let person: Person?
}

nonisolated struct SearchAssetPage: Codable {
    let total: Int
    let count: Int
    let items: [AssetDetail]
    let nextPage: String?
}

nonisolated struct SearchResponse: Codable {
    struct Albums: Codable { let items: [Album] }
    let albums: Albums?
    let assets: SearchAssetPage
}

nonisolated struct ExploreItem: Codable {
    let value: String
    let data: AssetDetail
}

nonisolated struct ExploreResponse: Codable {
    let fieldName: String
    let items: [ExploreItem]
}

// MARK: - map

/// one geotagged asset as returned by GET /map/markers.
nonisolated struct MapMarker: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let lat: Double
    let lon: Double
    let city: String?
    let state: String?
    let country: String?

    /// city, state or country, whichever the server knows first.
    var placeName: String? {
        [city, state, country].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.first
    }
}

// MARK: - memories

nonisolated struct Memory: Codable, Identifiable {
    struct MemoryData: Codable { let year: Int }
    let id: String
    let type: String
    let memoryAt: String
    let data: MemoryData
    let assets: [AssetDetail]
}

// MARK: - notifications

nonisolated enum NotificationLevel: String, Decodable, Hashable, Sendable {
    case success
    case error
    case warning
    case info

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .info
    }
}

nonisolated enum NotificationKind: String, Decodable, Hashable, Sendable {
    case jobFailed = "JobFailed"
    case backupFailed = "BackupFailed"
    case systemMessage = "SystemMessage"
    case albumInvite = "AlbumInvite"
    case albumUpdate = "AlbumUpdate"
    case custom = "Custom"

    /// a server newer than this build can name kinds we do not know; they still
    /// belong in the inbox, just without a dedicated icon.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .custom
    }
}

/// one entry of the server-side inbox, GET /notifications.
nonisolated struct ServerNotification: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let body: String?
    let level: NotificationLevel
    let kind: NotificationKind
    let createdAt: Date
    var readAt: Date?
    /// album the entry points at, lifted out of the free-form data payload.
    let albumID: String?

    var isUnread: Bool { readAt == nil }

    private enum CodingKeys: String, CodingKey {
        case id, title, description, level, type, createdAt, readAt, data
    }

    private struct AlbumPayload: Decodable { let albumId: String? }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decodeIfPresent(String.self, forKey: .description)
        level = try container.decodeIfPresent(NotificationLevel.self, forKey: .level) ?? .info
        kind = try container.decodeIfPresent(NotificationKind.self, forKey: .type) ?? .custom
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
            .flatMap(APIDate.parse) ?? Date()
        readAt = try container.decodeIfPresent(String.self, forKey: .readAt).flatMap(APIDate.parse)
        albumID = Self.albumID(in: container)
    }

    /// the server stringifies the payload before storing it, so the field comes
    /// back as json text; an object is accepted too in case that ever changes.
    private static func albumID(in container: KeyedDecodingContainer<CodingKeys>) -> String? {
        if let raw = try? container.decode(String.self, forKey: .data),
           let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
            return object["albumId"] as? String
        }
        return (try? container.decode(AlbumPayload.self, forKey: .data))?.albumId
    }
}
