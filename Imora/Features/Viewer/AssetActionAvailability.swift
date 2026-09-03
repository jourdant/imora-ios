import Foundation

/// One source of truth for viewer and grid action eligibility. Device presence,
/// server presence, ownership, and trash state are independent dimensions; a
/// single `isLocal` branch cannot model merged assets correctly.
nonisolated struct AssetActionAvailability: Equatable {
    let canBackUp: Bool
    let canDownload: Bool
    let canDeleteFromDevice: Bool
    let canTrashEverywhere: Bool
    let canFavorite: Bool
    let canEdit: Bool
    let canAddToAlbum: Bool
    let canShareLink: Bool
    let canArchive: Bool
    let canViewInTimeline: Bool
    let canRestore: Bool
    let canDeletePermanently: Bool
    /// a locked asset only exists inside the locked folder, which keeps
    /// share, info, favorite, edit, cast, download and permanent delete and
    /// nothing that would surface it anywhere else. a favorite set there
    /// only shows in the favorites view once the asset is moved back out.
    let isLocked: Bool
    let canLock: Bool
    let canUnlock: Bool

    init(
        asset: Asset,
        ownsAsset: Bool,
        localRemoteIdentifier: String? = nil,
        pairedLocalIdentifier: String? = nil
    ) {
        let hasServerCopy = !asset.isLocal || localRemoteIdentifier != nil
        let hasDeviceCopy = asset.isLocal || pairedLocalIdentifier != nil
        let isRemoteAsset = !asset.isLocal
        let isActive = !asset.isTrashed
        let isLocked = asset.visibility == .locked

        canBackUp = asset.isLocal && !asset.isLocalBackedUp && localRemoteIdentifier == nil
        canDownload = isRemoteAsset && isActive && pairedLocalIdentifier == nil
        canDeleteFromDevice = hasDeviceCopy
        canTrashEverywhere = ownsAsset && hasServerCopy && isActive && !isLocked
        canFavorite = ownsAsset && isRemoteAsset && isActive
        canEdit = ownsAsset && isRemoteAsset && asset.isImage && isActive
        canAddToAlbum = hasServerCopy && isActive && !isLocked
        canShareLink = ownsAsset && hasServerCopy && !isLocked
        canArchive = ownsAsset && isRemoteAsset && isActive && !isLocked
        canViewInTimeline = ownsAsset && isActive && asset.visibility == .timeline
        canRestore = ownsAsset && isRemoteAsset && asset.isTrashed
        canDeletePermanently = ownsAsset && isRemoteAsset && (asset.isTrashed || isLocked)
        self.isLocked = isLocked
        canLock = ownsAsset && isRemoteAsset && isActive && !isLocked
        canUnlock = ownsAsset && isRemoteAsset && isActive && isLocked
    }
}
