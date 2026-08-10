import Foundation

/// A tiny latest-request gate shared by album screens. Every GET receives a
/// ticket; a newer GET or a local projection invalidates earlier responses.
/// This keeps network completion order from becoming UI state order.
nonisolated struct LatestAlbumLoadGate {
    struct Ticket: Equatable {
        fileprivate let generation: UInt64
    }

    private var generation: UInt64 = 0

    mutating func begin() -> Ticket {
        generation &+= 1
        return Ticket(generation: generation)
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func accepts(_ ticket: Ticket) -> Bool {
        ticket.generation == generation
    }
}

/// Focused value-copy helpers for album UI projections. The API DTOs stay
/// immutable; optimistic screens replace a whole value and retain the original
/// as their exact rollback snapshot.
nonisolated extension Album {
    static func pending(
        name: String,
        assetCount: Int = 0,
        owner: CurrentUser? = nil
    ) -> Album {
        let timestamp = APIDate.string(from: Date())
        let albumUsers = owner.map { owner in
            [AlbumUser(
                role: "owner",
                user: User(
                    id: owner.id,
                    email: owner.email,
                    name: owner.name,
                    profileImagePath: owner.profileImagePath,
                    avatarColor: owner.avatarColor
                )
            )]
        } ?? []
        return Album(
            id: "optimistic-album-\(UUID().uuidString)",
            albumName: name,
            description: "",
            albumThumbnailAssetId: nil,
            assetCount: assetCount,
            albumUsers: albumUsers,
            shared: false,
            hasSharedLink: false,
            isActivityEnabled: true,
            createdAt: timestamp,
            updatedAt: timestamp,
            startDate: nil,
            endDate: nil,
            order: "desc"
        )
    }

    var isPending: Bool { id.hasPrefix("optimistic-album-") }

    /// Optimistic copies retain the version of the server value they project.
    /// A response for that same version is older than the projection even when
    /// its request began later. An older authoritative version is also rejected;
    /// only a genuinely newer server version may replace the current value.
    func reconcilingServerVersion(_ fetched: Album) -> Album {
        guard fetched.updatedAt >= updatedAt else { return self }
        guard self != fetched, updatedAt == fetched.updatedAt else { return fetched }
        return self
    }

    func withDetails(name: String, description: String) -> Album {
        copy(albumName: name, description: description)
    }

    func withOrder(_ order: String) -> Album {
        copy(order: order)
    }

    func withActivityEnabled(_ enabled: Bool) -> Album {
        copy(isActivityEnabled: enabled)
    }

    func withAssetCountDelta(_ delta: Int) -> Album {
        copy(assetCount: max(0, assetCount + delta))
    }

    func addingSharedUsers(_ users: [User]) -> Album {
        let existing = Set(albumUsers.map(\.user.id))
        let additions = users
            .filter { !existing.contains($0.id) }
            .map { AlbumUser(role: "editor", user: $0) }
        let projected = albumUsers + additions
        return copy(albumUsers: projected, shared: projected.count > 1)
    }

    func removingUser(_ userID: String) -> Album {
        let projected = albumUsers.filter { $0.user.id != userID }
        return copy(albumUsers: projected, shared: projected.count > 1)
    }

    private func copy(
        albumName: String? = nil,
        description: String? = nil,
        assetCount: Int? = nil,
        albumUsers: [AlbumUser]? = nil,
        shared: Bool? = nil,
        isActivityEnabled: Bool? = nil,
        order: String? = nil
    ) -> Album {
        Album(
            id: id,
            albumName: albumName ?? self.albumName,
            description: description ?? self.description,
            albumThumbnailAssetId: albumThumbnailAssetId,
            assetCount: assetCount ?? self.assetCount,
            albumUsers: albumUsers ?? self.albumUsers,
            shared: shared ?? self.shared,
            hasSharedLink: hasSharedLink,
            isActivityEnabled: isActivityEnabled ?? self.isActivityEnabled,
            createdAt: createdAt,
            updatedAt: updatedAt,
            startDate: startDate,
            endDate: endDate,
            order: order ?? self.order
        )
    }
}

nonisolated struct BulkMutationOutcome {
    let successfulIDs: Set<String>
    let duplicateIDs: Set<String>
    let failedIDs: Set<String>

    var satisfiedIDs: Set<String> { successfulIDs.union(duplicateIDs) }

    init(requestedIDs: Set<String>, results: [BulkIdResult]) {
        successfulIDs = Set(results.lazy.filter(\.success).map(\.id))
            .intersection(requestedIDs)
        duplicateIDs = Set(results.lazy.filter { $0.error == "duplicate" }.map(\.id))
            .intersection(requestedIDs)
        failedIDs = requestedIDs.subtracting(successfulIDs.union(duplicateIDs))
    }
}

nonisolated extension SharedLink {
    static func pending(options: SharedLinkOptions, type: String) -> SharedLink {
        SharedLink(
            id: "optimistic-link-\(UUID().uuidString)",
            key: UUID().uuidString,
            slug: options.slug.nilIfEmpty,
            type: type,
            description: options.description.nilIfEmpty,
            password: options.password.nilIfEmpty,
            expiresAt: options.expiresAt.map(APIDate.string),
            allowUpload: options.allowUpload,
            allowDownload: options.allowDownload,
            showMetadata: options.showMetadata,
            createdAt: APIDate.string(from: Date()),
            assets: nil
        )
    }

    func applying(_ options: SharedLinkOptions) -> SharedLink {
        SharedLink(
            id: id,
            key: key,
            slug: options.slug.nilIfEmpty,
            type: type,
            description: options.description.nilIfEmpty,
            password: options.password.nilIfEmpty,
            expiresAt: options.expiresAt.map(APIDate.string),
            allowUpload: options.allowUpload,
            allowDownload: options.allowDownload,
            showMetadata: options.showMetadata,
            createdAt: createdAt,
            assets: assets
        )
    }
}

private nonisolated extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
