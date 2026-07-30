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

    var body: some View {
        let cached = ImageLoader.shared.cachedImage(for: url, targetPixelSize: targetPixelSize)
        let loaded = image?.key == requestKey ? image?.image : cached
        let fallback = fallbackURL.flatMap {
            ImageLoader.shared.cachedImage(
                for: $0,
                targetPixelSize: fallbackTargetPixelSize ?? targetPixelSize
            )
        }
        let decodedPlaceholder = placeholder?.key == requestKey ? placeholder?.image : nil
        let displayImage = loaded ?? fallback ?? decodedPlaceholder
        let phase = loaded != nil ? "loaded" : fallback != nil ? "fallback" : decodedPlaceholder != nil ? "placeholder" : "empty"

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
    }
}

/// square grid tile for an asset, with video and favorite badges.
struct AssetTile: View {
    @Environment(SessionStore.self) private var session
    let asset: Asset

    @State private var thumbnailPhase = "empty"

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let client = session.client {
                    RemoteImage(
                        url: client.thumbnailURL(assetID: asset.id),
                        targetPixelSize: 640,
                        thumbhash: asset.thumbhash,
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
            .contentShape(.rect)
            .accessibilityIdentifier("asset-tile")
            // "assetid|phase" lets ui tests target one tile and observe its
            // thumbnail state at the same time.
            .accessibilityValue("\(asset.id)|\(thumbnailPhase)")
    }
}
