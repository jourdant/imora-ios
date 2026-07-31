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
}

extension Date.FormatStyle {
    /// asset dates are utc wall-clock values already shifted to local time; render them without zone conversion.
    func utc() -> Date.FormatStyle {
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

nonisolated struct UserPreferences: Codable, Hashable {
    let memories: FeatureToggle?
    let people: FeatureToggle?
    let folders: FeatureToggle?
    let ratings: FeatureToggle?
    let tags: FeatureToggle?
    let sharedLinks: FeatureToggle?

    var memoriesEnabled: Bool { memories?.enabled ?? true }
    var peopleEnabled: Bool { people?.enabled ?? true }
    var tagsEnabled: Bool { tags?.enabled ?? true }
    var ratingsEnabled: Bool { ratings?.enabled ?? false }
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

nonisolated enum AssetVisibility: String, Codable {
    case timeline
    case hidden
    case archive
    case locked
}

/// lightweight asset used across grids. built from timeline buckets or full dtos.
nonisolated struct Asset: Identifiable, Hashable {
    let id: String
    let ownerId: String
    let isImage: Bool
    var isFavorite: Bool
    var isTrashed: Bool
    var visibility: AssetVisibility
    let thumbhash: String?
    let fileCreatedAt: Date
    let localOffsetHours: Double
    /// milliseconds, nil for stills.
    let duration: Int?
    let livePhotoVideoId: String?
    let ratio: Double
    let city: String?
    let country: String?
    /// server upload time, drives the recently-added ordering.
    var createdAt: Date?

    var isVideo: Bool { !isImage }

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
    let checksum: String?

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
            createdAt: createdAt.flatMap { APIDate.parse($0) }
        )
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
    let name: String
    let thumbnailPath: String?
    let isHidden: Bool?
    let birthDate: String?
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

// MARK: - memories

nonisolated struct Memory: Codable, Identifiable {
    struct MemoryData: Codable { let year: Int }
    let id: String
    let type: String
    let memoryAt: String
    let data: MemoryData
    let assets: [AssetDetail]
}
