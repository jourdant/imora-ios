import AVFoundation
import SwiftUI

/// Floating media shown while an asset context menu is up. The grid's smaller
/// render is normally cached, so it paints immediately while the preview-sized
/// image loads. Videos take over only after their first frame is ready.
struct AssetContextPreview: View {
    @Environment(SessionStore.self) private var session
    let asset: Asset

    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    private var pairedLocalIdentifier: String? {
        asset.localIdentifier ?? session.backup?.localIdentifierByRemoteId[asset.id]
    }

    var body: some View {
        ZStack {
            if let localId = pairedLocalIdentifier {
                LocalPhotoImage(
                    localIdentifier: localId,
                    targetPixelSize: 1280,
                    fallbackTargetPixelSize: 640
                )
            } else if let client = session.client {
                RemoteImage(
                    url: client.thumbnailURL(assetID: asset.id, size: "preview", cacheKey: asset.thumbhash),
                    targetPixelSize: 1280,
                    thumbhash: asset.thumbhash,
                    fallbackURL: client.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash),
                    fallbackTargetPixelSize: 640
                )
            }
            if let player {
                PlayerLayerView(player: player)
            }
        }
        .clipped()
        .task { await startVideo() }
        .onDisappear {
            player?.pause()
            looper = nil
            player = nil
        }
    }

    private func startVideo() async {
        guard asset.isVideo, player == nil else { return }
        var item: AVPlayerItem?
        if let localId = pairedLocalIdentifier {
            // The paired device copy is free; a backed-up one stuck in iCloud
            // falls through to the server stream instead of downloading.
            item = await LocalImageLoader.shared.playerItem(localIdentifier: localId, allowsNetwork: false)
        }
        if item == nil, let client = session.client {
            let av = AVURLAsset(
                url: client.playbackURL(assetID: asset.id),
                options: ["AVURLAssetHTTPHeaderFieldsKey": client.authHeaders]
            )
            item = AVPlayerItem(asset: av)
        }
        guard let item, !Task.isCancelled else { return }
        let queue = AVQueuePlayer()
        queue.isMuted = true
        looper = AVPlayerLooper(player: queue, templateItem: item)
        queue.play()
        player = queue
    }
}

/// Bare video layer with no transport chrome. It stays hidden until the first
/// frame is ready, then fades over the still rather than popping in mid-render.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }

        private var readyObservation: NSKeyValueObservation?

        func fadeInOnFirstFrame() {
            guard let playerLayer = layer as? AVPlayerLayer,
                  !playerLayer.isReadyForDisplay
            else { return }
            alpha = 0
            readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, change in
                guard change.newValue == true else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.alpha == 0 else { return }
                    self.readyObservation = nil
                    UIView.animate(withDuration: 0.18) { self.alpha = 1 }
                }
            }
        }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.backgroundColor = .clear
        let layer = view.layer as? AVPlayerLayer
        layer?.player = player
        layer?.videoGravity = .resizeAspectFill
        view.fadeInOnFirstFrame()
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        (uiView.layer as? AVPlayerLayer)?.player = player
    }
}
