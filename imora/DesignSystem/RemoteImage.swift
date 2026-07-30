import SwiftUI

/// async image with thumbhash placeholder and downsampled decoding.
/// memory-cached images render on the first frame, and fast loads skip the
/// fade so cells never flicker when they scroll back into view.
struct RemoteImage: View {
    let url: URL
    var targetPixelSize: CGFloat = 320
    var thumbhash: String?
    var contentMode: ContentMode = .fill

    private let fallbackImage: UIImage?
    @State private var image: UIImage?
    @State private var placeholder: UIImage?

    init(
        url: URL,
        targetPixelSize: CGFloat = 320,
        thumbhash: String? = nil,
        fallbackURL: URL? = nil,
        contentMode: ContentMode = .fill
    ) {
        self.url = url
        self.targetPixelSize = targetPixelSize
        self.thumbhash = thumbhash
        self.contentMode = contentMode
        fallbackImage = fallbackURL.flatMap { ImageLoader.shared.cachedImage(for: $0) }
        _image = State(initialValue: ImageLoader.shared.cachedImage(for: url))
    }

    var body: some View {
        ZStack {
            if let displayImage = image ?? fallbackImage ?? placeholder {
                Image(uiImage: displayImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Color(.secondarySystemFill)
            }
        }
        .task(id: url) {
            guard image == nil else { return }
            let start = ContinuousClock.now

            if let thumbhash, placeholder == nil {
                placeholder = await Task.detached(priority: .utility) {
                    Thumbhash.image(fromBase64: thumbhash)
                }.value
            }
            guard image == nil, !Task.isCancelled else { return }

            let target = targetPixelSize
            let loaded = try? await Task.detached(priority: .userInitiated) { [url] in
                try await ImageLoader.shared.image(for: url, targetPixelSize: target)
            }.value
            guard !Task.isCancelled, let loaded else { return }

            if ContinuousClock.now - start < .milliseconds(120) {
                image = loaded
            } else {
                withAnimation(.easeIn(duration: 0.15)) { image = loaded }
            }
        }
    }
}

/// square grid tile for an asset, with video and favorite badges.
struct AssetTile: View {
    @Environment(SessionStore.self) private var session
    let asset: Asset

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let client = session.client {
                    RemoteImage(
                        url: client.thumbnailURL(assetID: asset.id),
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
    }
}
