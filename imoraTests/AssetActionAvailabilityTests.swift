import Testing
@testable import imora

@Suite("Asset action availability")
struct AssetActionAvailabilityTests {
    @Test("a device-only photo can be backed up and removed from the device")
    func localUnbackedPhoto() {
        let actions = AssetActionAvailability(
            asset: makeAsset(local: true, backedUp: false),
            ownsAsset: true
        )

        #expect(actions.canBackUp)
        #expect(actions.canDeleteFromDevice)
        #expect(!actions.canDownload)
        #expect(!actions.canTrashEverywhere)
        #expect(!actions.canEdit)
    }

    @Test("an owned server photo without a device copy can be downloaded")
    func remotePhotoWithoutDeviceCopy() {
        let actions = AssetActionAvailability(
            asset: makeAsset(),
            ownsAsset: true
        )

        #expect(actions.canDownload)
        #expect(actions.canFavorite)
        #expect(actions.canEdit)
        #expect(actions.canAddToAlbum)
        #expect(actions.canArchive)
        #expect(actions.canTrashEverywhere)
        #expect(!actions.canBackUp)
        #expect(!actions.canDeleteFromDevice)
    }

    @Test("a paired server photo offers separate device and everywhere deletion")
    func pairedRemotePhoto() {
        let actions = AssetActionAvailability(
            asset: makeAsset(),
            ownsAsset: true,
            pairedLocalIdentifier: "device-photo"
        )

        #expect(!actions.canDownload)
        #expect(actions.canDeleteFromDevice)
        #expect(actions.canTrashEverywhere)
    }

    @Test("a partner photo keeps non-mutating library actions")
    func nonOwnerRemotePhoto() {
        let actions = AssetActionAvailability(
            asset: makeAsset(),
            ownsAsset: false
        )

        #expect(actions.canDownload)
        #expect(actions.canAddToAlbum)
        #expect(!actions.canFavorite)
        #expect(!actions.canEdit)
        #expect(!actions.canArchive)
        #expect(!actions.canTrashEverywhere)
    }

    @Test("a trashed photo only exposes recovery actions")
    func trashedPhoto() {
        let actions = AssetActionAvailability(
            asset: makeAsset(trashed: true),
            ownsAsset: true
        )

        #expect(actions.canRestore)
        #expect(actions.canDeletePermanently)
        #expect(!actions.canDownload)
        #expect(!actions.canFavorite)
        #expect(!actions.canEdit)
        #expect(!actions.canAddToAlbum)
        #expect(!actions.canArchive)
        #expect(!actions.canTrashEverywhere)
    }

    @Test("a backed-up local photo can target its server copy")
    func backedUpLocalPhoto() {
        let actions = AssetActionAvailability(
            asset: makeAsset(local: true, backedUp: true),
            ownsAsset: true,
            localRemoteIdentifier: "remote-photo"
        )

        #expect(!actions.canBackUp)
        #expect(actions.canDeleteFromDevice)
        #expect(actions.canAddToAlbum)
        #expect(actions.canTrashEverywhere)
    }

    private func makeAsset(
        local: Bool = false,
        backedUp: Bool = false,
        trashed: Bool = false
    ) -> Asset {
        Asset(
            id: local ? "local-device-photo" : "remote-photo",
            ownerId: "owner",
            isImage: true,
            isFavorite: false,
            isTrashed: trashed,
            visibility: .timeline,
            thumbhash: nil,
            fileCreatedAt: .now,
            localOffsetHours: 0,
            duration: nil,
            livePhotoVideoId: nil,
            ratio: 1,
            city: nil,
            country: nil,
            createdAt: nil,
            localIdentifier: local ? "device-photo" : nil,
            isLocalBackedUp: backedUp
        )
    }
}
