import SwiftUI

/// async image with thumbhash placeholder and downsampled decoding.
struct RemoteImage: View {
    let url: URL
    var targetPixelSize: CGFloat = 320
    var thumbhash: String?
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var placeholder: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else if let placeholder {
                Image(uiImage: placeholder)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Color(.secondarySystemFill)
            }
        }
        .onAppear {
            image = ImageLoader.shared.cachedImage(for: url)
        }
        .task(id: url) {
            if image == nil, let thumbhash, placeholder == nil {
                placeholder = await decodeThumbhash(thumbhash)
            }
            guard image == nil else { return }
            let target = targetPixelSize
            let loaded = try? await Task.detached(priority: .userInitiated) { [url] in
                try await ImageLoader.shared.image(for: url, targetPixelSize: target)
            }.value
            guard !Task.isCancelled, let loaded else { return }
            withAnimation(.easeIn(duration: 0.12)) { image = loaded }
        }
    }

    private func decodeThumbhash(_ hash: String) async -> UIImage? {
        await Task.detached(priority: .utility) {
            Thumbhash.image(fromBase64: hash)
        }.value
    }
}

/// square grid tile for an asset, with video and favorite badges.
struct AssetTile: View {
    @Environment(SessionStore.self) private var session
    let asset: Asset

    var body: some View {
        GeometryReader { proxy in
            if let client = session.client {
                RemoteImage(
                    url: client.thumbnailURL(assetID: asset.id),
                    targetPixelSize: 320,
                    thumbhash: asset.thumbhash
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
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
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(.rect)
        .accessibilityIdentifier("asset-tile")
    }
}
