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
    let canArchive: Bool
    let canRestore: Bool
    let canDeletePermanently: Bool

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

        canBackUp = asset.isLocal && !asset.isLocalBackedUp && localRemoteIdentifier == nil
        canDownload = isRemoteAsset && isActive && pairedLocalIdentifier == nil
        canDeleteFromDevice = hasDeviceCopy
        canTrashEverywhere = ownsAsset && hasServerCopy && isActive
        canFavorite = ownsAsset && isRemoteAsset && isActive
        canEdit = ownsAsset && isRemoteAsset && asset.isImage && isActive
        canAddToAlbum = hasServerCopy && isActive
        canArchive = ownsAsset && isRemoteAsset && isActive
        canRestore = ownsAsset && isRemoteAsset && asset.isTrashed
        canDeletePermanently = ownsAsset && isRemoteAsset && asset.isTrashed
    }
}
