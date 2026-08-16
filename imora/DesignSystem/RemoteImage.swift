import SwiftUI

/// async image with thumbhash placeholder and downsampled decoding.
/// memory-cached images render on the first frame, and fast loads skip the
/// fade so cells never flicker when they scroll back into view.
struct RemoteImage: View {
    let url: URL
    var targetPixelSize: CGFloat = 320
    var thumbhash: String?
    var fallbackURL: URL?
    var fallbackTargetPixelSize: CGFloat?
    var contentMode: ContentMode = .fill

    @State private var image: KeyedImage?
    @State private var placeholder: KeyedImage?
    @State private var fallbackImage: KeyedImage?

    private struct KeyedImage {
        let key: String
        let image: UIImage
    }

    private var requestKey: String {
        ImageLoader.shared.requestKey(for: url, targetPixelSize: targetPixelSize)
    }

    private var fallbackPixelSize: CGFloat {
        fallbackTargetPixelSize ?? targetPixelSize
    }

    /// walked in priority order and stopped at the first hit, so a tile already
    /// holding its image never touches the pipeline cache: the lookup builds a
    /// request and takes the cache's lock, and a grid runs it once per tile per
    /// pass.
    private func displayImage(key: String) -> UIImage? {
        if let image, image.key == key { return image.image }
        if let cached = ImageLoader.shared.cachedImage(for: url, targetPixelSize: targetPixelSize) {
            return cached
        }
        if let fallbackImage, fallbackImage.key == key { return fallbackImage.image }
        if let fallbackURL,
           let cached = ImageLoader.shared.cachedImage(for: fallbackURL, targetPixelSize: fallbackPixelSize) {
            return cached
        }
        if let placeholder, placeholder.key == key { return placeholder.image }
        return nil
    }

    var body: some View {
        // one string build per pass instead of the five the computed keys used
        // to cost; a grid tile's key is a full url and this is its hot path.
        let key = requestKey
        let taskID = "\(key)|\(thumbhash ?? "")"

        ZStack {
            if let displayImage = displayImage(key: key) {
                Image(uiImage: displayImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    // swiftui does not animate an image content swap on its
                    // own, so without this the slow-path fade below lands as
                    // a hard cut when the sharper render arrives.
                    .contentTransition(.opacity)
            } else {
                Color(.secondarySystemFill)
            }
        }
        .task(id: taskID) {
            if let cached = ImageLoader.shared.cachedImage(for: url, targetPixelSize: targetPixelSize) {
                image = KeyedImage(key: requestKey, image: cached)
                return
            }

            let key = requestKey
            let start = ContinuousClock.now
            if let thumbhash, placeholder?.key != key {
                let decodeTask = Task.detached(priority: .utility) {
                    Thumbhash.image(fromBase64: thumbhash)
                }
                let decoded = await withTaskCancellationHandler {
                    await decodeTask.value
                } onCancel: {
                    decodeTask.cancel()
                }
                guard !Task.isCancelled, let decoded else { return }
                placeholder = KeyedImage(key: key, image: decoded)
            }

            guard !Task.isCancelled else { return }
            let loaded = try? await ImageLoader.shared.image(
                for: url,
                targetPixelSize: targetPixelSize
            )
            guard !Task.isCancelled, let loaded else { return }
            let keyed = KeyedImage(key: key, image: loaded)

            if ContinuousClock.now - start < .milliseconds(120) {
                image = keyed
            } else {
                withAnimation(.easeIn(duration: 0.15)) { image = keyed }
            }
        }
        // the smaller render of the same photo - the one the grid showed - is
        // usually a disk cache hit, so it paints the view while the full size
        // is still on the wire instead of leaving a flat placeholder.
        .task(id: taskID) {
            guard let fallbackURL, image?.key != requestKey else { return }
            let key = requestKey
            guard ImageLoader.shared.cachedImage(for: url, targetPixelSize: targetPixelSize) == nil,
                  ImageLoader.shared.cachedImage(for: fallbackURL, targetPixelSize: fallbackPixelSize) == nil
            else { return }
            let loaded = try? await ImageLoader.shared.image(
                for: fallbackURL,
                targetPixelSize: fallbackPixelSize
            )
            guard !Task.isCancelled, let loaded, image?.key != key else { return }
            fallbackImage = KeyedImage(key: key, image: loaded)
        }
    }
}

/// async device-library thumbnail, the photokit sibling of remoteimage.
struct LocalPhotoImage: View {
    let localIdentifier: String
    var targetPixelSize: CGFloat = 640
    /// smaller render of the same asset, taken from the cache only. the viewer
    /// points it at the grid's size so a page opens on the tile's pixels
    /// instead of a placeholder while photokit produces the big one.
    var fallbackTargetPixelSize: CGFloat?
    var contentMode: ContentMode = .fill
    /// photokit could not produce the asset - it was deleted from the library
    /// behind our back, or is an icloud original that will not download. hosts
    /// use this to fall back to the server copy instead of showing nothing.
    var onUnavailable: (() -> Void)?

    @State private var image: KeyedImage?

    private struct KeyedImage {
        let key: String
        let image: UIImage
    }

    private var requestKey: String {
        "\(localIdentifier)#\(Int(targetPixelSize))"
    }

    private var cachedFallback: UIImage? {
        guard let fallbackTargetPixelSize else { return nil }
        return LocalImageLoader.shared.cachedImage(
            localIdentifier: localIdentifier,
            targetPixelSize: fallbackTargetPixelSize
        )
    }

    var body: some View {
        let key = requestKey
        // the photokit cache is only consulted when this view is not already
        // holding the render, the same short circuit remoteimage takes.
        let display = (image?.key == key ? image?.image : nil)
            ?? LocalImageLoader.shared.cachedImage(localIdentifier: localIdentifier, targetPixelSize: targetPixelSize)
            ?? cachedFallback
        ZStack {
            if let display {
                Image(uiImage: display)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    // same as remoteimage: makes the slow-path fade real
                    // instead of a hard cut on the content swap.
                    .contentTransition(.opacity)
            } else {
                Color(.secondarySystemFill)
            }
        }
        .task(id: key) {
            guard image?.key != key else { return }
            let start = ContinuousClock.now
            let loaded = await LocalImageLoader.shared.image(
                localIdentifier: localIdentifier,
                targetPixelSize: targetPixelSize
            )
            guard !Task.isCancelled else { return }
            guard let loaded else { return onUnavailable?() ?? () }
            let keyed = KeyedImage(key: key, image: loaded)
            // same rule as remoteimage: fast loads swap in place, slow ones
            // fade so a late arrival never pops over the fallback.
            if ContinuousClock.now - start < .milliseconds(120) {
                image = keyed
            } else {
                withAnimation(.easeIn(duration: 0.15)) { image = keyed }
            }
        }
    }
}

/// square grid tile for an asset, with video, favorite and backup badges.
struct AssetTile: View {
    @Environment(SessionStore.self) private var session
    let asset: Asset
    /// backup status in the corner plus the upload progress overlay. only
    /// the main timeline shows these, matching the official client.
    var showsBackupBadge = false

    /// set when photokit cannot serve the paired device copy, so the tile
    /// stops asking and renders the server thumbnail instead.
    @State private var localUnavailable = false

    /// the device copy is free, already decoded by photokit and needs no
    /// network, so it wins whenever the backup index pairs one with this
    /// asset. edited server copies are excluded from that map.
    private var deviceIdentifier: String? {
        guard !localUnavailable else { return nil }
        return asset.localIdentifier ?? session.backup?.localIdentifierByRemoteId[asset.id]
    }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let localId = deviceIdentifier {
                    LocalPhotoImage(
                        localIdentifier: localId,
                        onUnavailable: { localUnavailable = true }
                    )
                } else if let client = session.client {
                    RemoteImage(
                        url: client.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash),
                        targetPixelSize: 640,
                        thumbhash: asset.thumbhash
                    )
                }
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                if let duration = asset.durationLabel {
                    Label(duration, systemImage: "play.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.4), in: .capsule)
                        .padding(5)
                } else if asset.isLivePhoto {
                    Image(systemName: "livephoto")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 3)
                        .padding(7)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if asset.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 3)
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showsBackupBadge { backupBadge }
            }
            .overlay {
                if showsBackupBadge { uploadOverlay }
            }
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("asset-tile")
    }

    private var accessibilitySummary: String {
        var parts = [
            asset.isVideo ? "Video" : (asset.isLivePhoto ? "Live Photo" : "Photo"),
            asset.localDate.formatted(date: .long, time: .shortened),
        ]
        if let duration = asset.durationLabel { parts.append(duration) }
        if asset.isFavorite { parts.append("Favorite") }
        if showsBackupBadge { parts.append(backupAccessibilitySummary) }
        return parts.joined(separator: ", ")
    }

    private var backupAccessibilitySummary: String {
        switch uploadState {
        case .uploading(let fraction):
            return "Backing up, \(Int(fraction * 100)) percent"
        case .failed:
            return "Backup failed"
        case nil:
            if asset.isLocal {
                return asset.isLocalBackedUp ? "Backed up" : "Not backed up"
            }
            return session.backup?.backedUpRemoteIds.contains(asset.id) == true
                ? "Backed up" : "Stored in cloud"
        }
    }

    // MARK: - backup status

    private var uploadState: LocalUploadState? {
        guard let localId = asset.localIdentifier else { return nil }
        return session.backup?.uploadStates[localId]
    }

    @ViewBuilder private var backupBadge: some View {
        if uploadState == nil {
            if asset.isLocal {
                badgeIcon(asset.isLocalBackedUp ? "checkmark.icloud" : "icloud.slash")
            } else if session.backup?.backedUpRemoteIds.contains(asset.id) == true {
                badgeIcon("checkmark.icloud")
            } else {
                badgeIcon("icloud")
            }
        }
    }

    private func badgeIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 2.5)
            .padding(6)
            .accessibilityIdentifier("badge-\(name)")
    }

    @ViewBuilder private var uploadOverlay: some View {
        switch uploadState {
        case .uploading(let fraction):
            ZStack {
                Color.black.opacity(0.54)
                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.24), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: max(0.03, fraction))
                            .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.2), value: fraction)
                    }
                    .frame(width: 36, height: 36)
                    Text("\(Int(fraction * 100))%")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
            }
        case .failed:
            ZStack {
                Color.black.opacity(0.58)
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                    Text("Error")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
        case nil:
            EmptyView()
        }
    }
}
