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
    /// device twin of a server asset. its cached thumbnail - the same pixels
    /// the tile showed before the upload - stands in until the remote loads,
    /// so the local-to-server swap never flashes a placeholder.
    var localFallbackIdentifier: String?
    var contentMode: ContentMode = .fill
    /// reports loaded, fallback, placeholder or empty so hosts can expose the
    /// state to ui tests without altering this view's accessibility tree.
    var onPhaseChange: ((String) -> Void)?

    @State private var image: KeyedImage?
    @State private var placeholder: KeyedImage?

    private struct KeyedImage {
        let key: String
        let image: UIImage
    }

    private var requestKey: String {
        ImageLoader.shared.requestKey(for: url, targetPixelSize: targetPixelSize)
    }

    private var taskID: String {
        "\(requestKey)|\(thumbhash ?? "")"
    }

    private var cachedLocalFallback: UIImage? {
        guard let localFallbackIdentifier else { return nil }
        return LocalImageLoader.shared.cachedImage(
            localIdentifier: localFallbackIdentifier,
            targetPixelSize: targetPixelSize
        )
    }

    var body: some View {
        let cached = ImageLoader.shared.cachedImage(for: url, targetPixelSize: targetPixelSize)
        let loaded = image?.key == requestKey ? image?.image : cached
        let fallback = fallbackURL.flatMap {
            ImageLoader.shared.cachedImage(
                for: $0,
                targetPixelSize: fallbackTargetPixelSize ?? targetPixelSize
            )
        }
        let localFallback = cachedLocalFallback
        let decodedPlaceholder = placeholder?.key == requestKey ? placeholder?.image : nil
        let displayImage = loaded ?? fallback ?? localFallback ?? decodedPlaceholder
        let phase = loaded != nil ? "loaded" : fallback != nil || localFallback != nil ? "fallback" : decodedPlaceholder != nil ? "placeholder" : "empty"

        ZStack {
            if let displayImage {
                Image(uiImage: displayImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Color(.secondarySystemFill)
            }
        }
        .onChange(of: phase, initial: true) { _, newPhase in
            onPhaseChange?(newPhase)
        }
        .task(id: taskID) {
            if let cached = ImageLoader.shared.cachedImage(for: url, targetPixelSize: targetPixelSize) {
                image = KeyedImage(key: requestKey, image: cached)
                return
            }

            let key = requestKey
            let start = ContinuousClock.now
            // real pixels from the device twin beat a thumbhash blur.
            if let thumbhash, placeholder?.key != key, cachedLocalFallback == nil {
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
    }
}

/// async device-library thumbnail, the photokit sibling of remoteimage.
struct LocalPhotoImage: View {
    let localIdentifier: String
    var targetPixelSize: CGFloat = 640
    var contentMode: ContentMode = .fill
    var onPhaseChange: ((String) -> Void)?

    @State private var image: KeyedImage?

    private struct KeyedImage {
        let key: String
        let image: UIImage
    }

    private var requestKey: String {
        "\(localIdentifier)#\(Int(targetPixelSize))"
    }

    var body: some View {
        let cached = LocalImageLoader.shared.cachedImage(localIdentifier: localIdentifier, targetPixelSize: targetPixelSize)
        let display = image?.key == requestKey ? image?.image : cached
        ZStack {
            if let display {
                Image(uiImage: display)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Color(.secondarySystemFill)
            }
        }
        .onChange(of: display == nil, initial: true) { _, isEmpty in
            onPhaseChange?(isEmpty ? "empty" : "loaded")
        }
        .task(id: requestKey) {
            let key = requestKey
            guard image?.key != key else { return }
            let loaded = await LocalImageLoader.shared.image(
                localIdentifier: localIdentifier,
                targetPixelSize: targetPixelSize
            )
            guard !Task.isCancelled, let loaded else { return }
            image = KeyedImage(key: key, image: loaded)
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

    @State private var thumbnailPhase = "empty"

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let localId = asset.localIdentifier {
                    LocalPhotoImage(
                        localIdentifier: localId,
                        onPhaseChange: { thumbnailPhase = $0 }
                    )
                } else if let client = session.client {
                    RemoteImage(
                        url: client.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash),
                        targetPixelSize: 640,
                        thumbhash: asset.thumbhash,
                        localFallbackIdentifier: showsBackupBadge
                            ? session.backup?.localIdentifierByRemoteId[asset.id]
                            : nil,
                        onPhaseChange: { thumbnailPhase = $0 }
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
            .accessibilityIdentifier("asset-tile")
            // "assetid|phase" lets ui tests target one tile and observe its
            // thumbnail state at the same time; badge grids append the badge
            // state as a third segment.
            .accessibilityValue(
                showsBackupBadge
                    ? "\(asset.id)|\(thumbnailPhase)|\(badgeToken)"
                    : "\(asset.id)|\(thumbnailPhase)"
            )
    }

    // MARK: - backup status

    private var uploadState: LocalUploadState? {
        guard let localId = asset.localIdentifier else { return nil }
        return session.backup?.uploadStates[localId]
    }

    private var badgeToken: String {
        switch uploadState {
        case .uploading: "uploading"
        case .failed: "error"
        case nil:
            if asset.isLocal {
                asset.isLocalBackedUp ? "cloud-done" : "cloud-off"
            } else {
                session.backup?.backedUpRemoteIds.contains(asset.id) == true ? "cloud-done" : "cloud"
            }
        }
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
                Color.red.opacity(0.6)
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 30))
                    Text("Error")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(.white)
            }
        case nil:
            EmptyView()
        }
    }
}
