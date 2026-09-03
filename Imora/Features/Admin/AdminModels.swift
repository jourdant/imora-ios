import Foundation

// MARK: - users

/// one account as the admin api returns it. quota fields are null for an
/// unlimited account, deletedAt is set once a deletion is queued.
nonisolated struct AdminUser: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var email: String
    var name: String
    var isAdmin: Bool
    var avatarColor: String?
    var profileImagePath: String?
    let createdAt: String
    var updatedAt: String
    var deletedAt: String?
    var oauthId: String?
    var quotaSizeInBytes: Int64?
    var quotaUsageInBytes: Int64?
    var shouldChangePassword: Bool?
    /// active, removing or deleted.
    var status: String?
    var storageLabel: String?

    var isDeleted: Bool { deletedAt != nil }

    /// a queued deletion can be undone until the server starts removing.
    var canRestore: Bool { isDeleted && status == "deleted" }

    var hasQuota: Bool {
        guard let quotaSizeInBytes else { return false }
        return quotaSizeInBytes >= 0
    }

    var asUser: User {
        User(id: id, email: email, name: name, profileImagePath: profileImagePath, avatarColor: avatarColor)
    }

    var createdDate: Date? { APIDate.parse(createdAt) }
    var updatedDate: Date? { APIDate.parse(updatedAt) }
    var deletedDate: Date? { deletedAt.flatMap(APIDate.parse) }
}

/// the switches the detail page lists. every group is optional so a server
/// that predates one of them still decodes.
nonisolated struct AdminUserPreferences: Decodable, Sendable {
    struct Toggle: Decodable { let enabled: Bool? }
    struct Purchase: Decodable { let showSupportBadge: Bool? }
    struct Cast: Decodable { let gCastEnabled: Bool? }

    let emailNotifications: Toggle?
    let folders: Toggle?
    let memories: Toggle?
    let people: Toggle?
    let ratings: Toggle?
    let sharedLinks: Toggle?
    let tags: Toggle?
    let purchase: Purchase?
    let cast: Cast?

    /// title and state in the order the web page shows them.
    var features: [(title: String, enabled: Bool)] {
        [
            ("Email Notifications", emailNotifications?.enabled ?? false),
            ("Folders", folders?.enabled ?? false),
            ("Memories", memories?.enabled ?? false),
            ("People", people?.enabled ?? false),
            ("Rating", ratings?.enabled ?? false),
            ("Shared Links", sharedLinks?.enabled ?? false),
            ("Supporter Badge", purchase?.showSupportBadge ?? false),
            ("Tags", tags?.enabled ?? false),
            ("Google Cast", cast?.gCastEnabled ?? false),
        ]
    }
}

/// one login of an account, GET /admin/users/{id}/sessions.
nonisolated struct UserSession: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let deviceType: String
    let deviceOS: String
    let appVersion: String?
    let createdAt: String
    let updatedAt: String
    let current: Bool
    let expiresAt: String?

    var lastSeen: Date? { APIDate.parse(updatedAt) }

    /// sf symbol standing in for the web's platform icons.
    var icon: String {
        if deviceOS == "Android" { return "candybarphone" }
        if deviceOS == "iOS" || deviceOS == "macOS" { return "apple.logo" }
        if deviceOS.contains("Safari") { return "safari" }
        if deviceOS.contains("Windows") { return "pc" }
        if deviceOS == "Linux" || deviceOS == "Ubuntu" { return "terminal" }
        if deviceOS == "Chrome OS"
            || deviceType == "Chrome"
            || deviceType == "Chromium"
            || deviceType == "Mobile Chrome" {
            return "globe"
        }
        if deviceOS == "Google Cast" { return "tv" }
        return "questionmark.circle"
    }

    var title: String {
        guard !deviceType.isEmpty || !deviceOS.isEmpty else { return "Unknown" }
        var text = "\(deviceOS.isEmpty ? "Unknown" : deviceOS) • \(deviceType.isEmpty ? "Unknown" : deviceType)"
        if let appVersion, !appVersion.isEmpty { text += " (v\(appVersion))" }
        return text
    }
}

nonisolated struct AssetStatistics: Decodable, Sendable {
    let images: Int
    let videos: Int
    let total: Int
}

/// daily activity over a date range, GET /admin/users/{id}/calendar-heatmap.
nonisolated struct CalendarHeatmap: Decodable, Sendable {
    struct Day: Decodable, Identifiable {
        let date: String
        let count: Int
        var id: String { date }
    }

    let from: String
    let to: String
    let series: [Day]
    let totalCount: Int
}

/// the web's heatmap window: 52 weeks ending today, opened on a sunday so
/// the grid starts on a full column.
nonisolated enum HeatmapRange {
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func current(now: Date = Date()) -> (from: String, to: String) {
        let calendar = utcCalendar
        let to = calendar.startOfDay(for: now)
        let back = calendar.date(byAdding: .weekOfYear, value: -51, to: to) ?? to
        let from = calendar.date(byAdding: .day, value: 1, to: back) ?? back
        let weekday = calendar.component(.weekday, from: from)
        let sunday = calendar.date(byAdding: .day, value: -(weekday - 1), to: from) ?? from
        return (dayFormatter.string(from: sunday), dayFormatter.string(from: to))
    }

    /// series dates come back either date-only or as full timestamps.
    static func parse(_ raw: String) -> Date? {
        dayFormatter.date(from: String(raw.prefix(10))) ?? APIDate.parse(raw)
    }
}

// MARK: - byte units

/// the web's byte-units helpers: binary units with a short label.
nonisolated enum BinaryByteFormat {
    private static let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]

    /// number and unit apart, for layouts that style them differently.
    static func components(_ bytes: Int64, maxFractionDigits: Int = 1) -> (value: String, unit: String) {
        let value = max(0, Double(bytes))
        let magnitude = value < 1 ? 0 : min(units.count - 1, Int(log(value) / log(1024)))
        let scaled = value / pow(1024, Double(magnitude))
        let number = scaled.formatted(.number.precision(.fractionLength(0...maxFractionDigits)))
        return (number, units[magnitude])
    }

    static func string(_ bytes: Int64, maxFractionDigits: Int = 1) -> String {
        let parts = components(bytes, maxFractionDigits: maxFractionDigits)
        return "\(parts.value) \(parts.unit)"
    }

    static func gibibytes(from bytes: Int64) -> Double {
        Double(bytes) / pow(1024, 3)
    }

    static func bytes(fromGibibytes value: Double) -> Int64 {
        Int64((value * pow(1024, 3)).rounded())
    }
}

// MARK: - queues

nonisolated struct QueueStatistics: Decodable, Hashable, Sendable {
    let active: Int
    let completed: Int
    let delayed: Int
    let failed: Int
    let paused: Int
    let waiting: Int

    /// what the queue card counts as waiting.
    var waitingTotal: Int { waiting + paused + delayed }
}

/// one server job queue, GET /queues. the name is kept raw so a queue this
/// build does not know still decodes and can be paused or resumed.
nonisolated struct Queue: Decodable, Identifiable, Hashable, Sendable {
    let name: String
    let isPaused: Bool
    let statistics: QueueStatistics

    var id: String { name }
    var kind: QueueKind? { QueueKind(rawValue: name) }
    var isIdle: Bool { statistics.active + statistics.waiting == 0 && !isPaused }
    var title: String { kind?.title ?? name }
}

/// GET /jobs on servers without the queues api.
nonisolated struct LegacyQueue: Decodable, Sendable {
    struct Status: Decodable { let isPaused: Bool }
    let jobCounts: QueueStatistics
    let queueStatus: Status
}

nonisolated enum QueueCommand: String, Sendable {
    case start
    case pause
    case resume
    case empty
    case clearFailed = "clear-failed"
}

/// the queues the web panel knows, with their card texts.
nonisolated enum QueueKind: String, CaseIterable, Sendable {
    case thumbnailGeneration
    case metadataExtraction
    case videoConversion
    case faceDetection
    case facialRecognition
    case smartSearch
    case duplicateDetection
    case backgroundTask
    case storageTemplateMigration
    case migration
    case search
    case sidecar
    case library
    case notifications
    case backupDatabase
    case ocr
    case workflow
    case integrityCheck
    case editor

    /// the buttons an idle card offers. all and refresh are optional, the
    /// missing button always exists.
    struct Buttons {
        var all: String?
        var refresh: String?
        var missing: String
    }

    /// card order of the web panel; queues outside it only show in the
    /// paused-queues action.
    static let panelOrder: [QueueKind] = [
        .thumbnailGeneration, .metadataExtraction, .library, .sidecar, .smartSearch,
        .duplicateDetection, .faceDetection, .facialRecognition, .ocr, .videoConversion,
        .storageTemplateMigration, .migration,
    ]

    var title: String {
        switch self {
        case .thumbnailGeneration: "Generate Thumbnails"
        case .metadataExtraction: "Extract Metadata"
        case .videoConversion: "Transcode Videos"
        case .faceDetection: "Face Detection"
        case .facialRecognition: "Facial Recognition"
        case .smartSearch: "Smart Search"
        case .duplicateDetection: "Duplicate Detection"
        case .backgroundTask: "Background Tasks"
        case .storageTemplateMigration: "Storage Template Migration"
        case .migration: "Migration"
        case .search: "Search"
        case .sidecar: "Sidecar Metadata"
        case .library: "External Libraries"
        case .notifications: "Notifications"
        case .backupDatabase: "Backup Database"
        case .ocr: "Optical Character Recognition"
        case .workflow: "Workflows"
        case .integrityCheck: "Integrity Checks"
        case .editor: "Editor"
        }
    }

    var subtitle: String? {
        switch self {
        case .thumbnailGeneration:
            "Generate large, small and blurred thumbnails for each asset, as well as thumbnails for each person."
        case .metadataExtraction:
            "Extract metadata information from each asset, such as GPS, faces and resolution."
        case .videoConversion:
            "Transcode videos for wider compatibility with browsers and devices."
        case .faceDetection:
            "Detect the faces in assets using machine learning. For videos, only the thumbnail is considered. Refresh reprocesses all assets. Reset additionally clears all current face data. Missing queues assets that haven’t been processed yet. Detected faces will be queued for Facial Recognition once Face Detection is complete, grouping them into existing or new people."
        case .facialRecognition:
            "Group detected faces into people. This step runs after Face Detection is complete. Reset reclusters all faces. Missing queues faces that don’t have a person assigned."
        case .smartSearch:
            "Run machine learning on assets to support smart search."
        case .duplicateDetection:
            "Run machine learning on assets to detect similar images."
        case .storageTemplateMigration:
            "Apply the current storage template to previously uploaded assets."
        case .migration:
            "Migrate thumbnails for assets and faces to the latest folder structure."
        case .sidecar:
            "Discover or synchronize sidecar metadata from the filesystem."
        case .library:
            "Scan external libraries for new and changed assets."
        case .ocr:
            "Recognize text in images with machine learning so it can be searched."
        case .backgroundTask, .search, .notifications, .backupDatabase, .workflow, .integrityCheck, .editor:
            nil
        }
    }

    var icon: String {
        switch self {
        case .thumbnailGeneration: "photo.on.rectangle"
        case .metadataExtraction: "tablecells"
        case .videoConversion: "video"
        case .faceDetection: "faceid"
        case .facialRecognition: "person.2.crop.square.stack"
        case .smartSearch: "sparkle.magnifyingglass"
        case .duplicateDetection: "doc.on.doc"
        case .backgroundTask: "tray.full"
        case .storageTemplateMigration: "folder.badge.gearshape"
        case .migration: "arrow.right.doc.on.clipboard"
        case .search: "magnifyingglass"
        case .sidecar: "doc.text"
        case .library: "books.vertical"
        case .notifications: "bell"
        case .backupDatabase: "externaldrive.badge.timemachine"
        case .ocr: "text.viewfinder"
        case .workflow: "point.3.connected.trianglepath.dotted"
        case .integrityCheck: "checkmark.seal"
        case .editor: "pencil"
        }
    }

    var buttons: Buttons? {
        switch self {
        case .thumbnailGeneration, .metadataExtraction, .smartSearch, .duplicateDetection, .ocr, .videoConversion:
            Buttons(all: "All", missing: "Missing")
        case .library:
            Buttons(missing: "Rescan")
        case .sidecar:
            Buttons(all: "Sync", missing: "Discover")
        case .faceDetection:
            Buttons(all: "Reset", refresh: "Refresh", missing: "Missing")
        case .facialRecognition:
            Buttons(all: "Reset", missing: "Missing")
        case .storageTemplateMigration, .migration:
            Buttons(missing: "Start")
        default:
            nil
        }
    }

    /// queues whose feature is switched off on the server show a disabled
    /// card, exactly like the web panel.
    func isDisabled(features: ServerFeatures?) -> Bool {
        switch self {
        case .sidecar: features?.sidecar == false
        case .smartSearch: features?.smartSearch == false
        case .duplicateDetection: features?.duplicateDetection == false
        case .faceDetection, .facialRecognition: features?.facialRecognition == false
        case .ocr: features?.ocr == false
        default: false
        }
    }

    /// forcing these clears every named person, so the web asks first.
    var confirmsForcedStart: Bool {
        self == .faceDetection || self == .facialRecognition
    }
}

/// jobs the create-job dialog can queue, POST /jobs.
nonisolated enum ManualJob: String, CaseIterable, Identifiable, Sendable {
    case personCleanup = "person-cleanup"
    case tagCleanup = "tag-cleanup"
    case userCleanup = "user-cleanup"
    case memoryCleanup = "memory-cleanup"
    case memoryCreate = "memory-create"
    case backupDatabase = "backup-database"
    case integrityMissingFiles = "integrity-missing-files"
    case integrityUntrackedFiles = "integrity-untracked-files"
    case integrityChecksumMismatch = "integrity-checksum-mismatch"
    case integrityMissingFilesRefresh = "integrity-missing-files-refresh"
    case integrityUntrackedFilesRefresh = "integrity-untracked-files-refresh"
    case integrityChecksumMismatchRefresh = "integrity-checksum-mismatch-refresh"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .personCleanup: "Person Cleanup"
        case .tagCleanup: "Tag Cleanup"
        case .userCleanup: "User Cleanup"
        case .memoryCleanup: "Memory Cleanup"
        case .memoryCreate: "Memory Generation"
        case .backupDatabase: "Backup Database"
        case .integrityMissingFiles: "Missing Files"
        case .integrityUntrackedFiles: "Untracked Files"
        case .integrityChecksumMismatch: "Checksum Mismatch"
        case .integrityMissingFilesRefresh: "Missing Files (Refresh)"
        case .integrityUntrackedFilesRefresh: "Untracked Files (Refresh)"
        case .integrityChecksumMismatchRefresh: "Checksum Mismatch (Refresh)"
        }
    }

    var group: String {
        switch self {
        case .personCleanup, .tagCleanup, .userCleanup, .memoryCleanup, .memoryCreate: "Cleanup"
        case .backupDatabase: "Database"
        default: "Integrity Checks"
        }
    }

    static let groups: [String] = ["Cleanup", "Database", "Integrity Checks"]
}
