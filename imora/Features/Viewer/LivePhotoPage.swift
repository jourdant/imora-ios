import AVFoundation
import SwiftUI

/// live photo page. the still is the asset and stays on screen at rest, with
/// the paired clip driven by the viewer's shared playback engine so it can be
/// scrubbed and stepped frame by frame rather than only played as a whole.
struct LivePhotoPage: View {
    @Environment(SessionStore.self) private var session
    let asset: Asset
    let deviceIdentifier: String?
    let isActive: Bool
    let forcesMute: Bool
    let playback: VideoPlayback
    let onZoomChanged: (Bool) -> Void

    /// photokit could not serve the device copy after all; the page falls back
    /// to the server for the rest of its life.
    @State private var localUnavailable = false

    private var localIdentifier: String? {
        localUnavailable ? nil : deviceIdentifier
    }

    var body: some View {
        // the zoom container only reassigns its hosted root when the content
        // id changes, so the id has to name the source: losing the device copy
        // would otherwise keep the failed still on screen forever.
        ZoomableScrollView(
            contentID: "\(asset.id)#\(localIdentifier ?? "remote")",
            onZoomChanged: onZoomChanged
        ) {
            MediaSurfaceStack(
                assetID: asset.id,
                aspectRatio: asset.ratio,
                mode: .livePhoto,
                posterLocalIdentifier: localIdentifier,
                posterURL: posterURL,
                posterFallbackURL: posterFallbackURL,
                thumbhash: asset.thumbhash,
                playback: playback,
                onPosterUnavailable: { localUnavailable = true }
            )
            // press and hold plays the clip, the same gesture the system photos
            // app uses. the handler only touches the playback reference, which
            // outlives the hosted root the zoom container caches.
            .onLongPressGesture(minimumDuration: 0.35) {
                guard playback.ownerID == asset.id, !playback.isPlaying else { return }
                playback.togglePlayPause()
            }
        }
        .task(id: "\(asset.id):\(isActive):\(forcesMute):\(localIdentifier ?? "remote")") {
            guard isActive else {
                playback.release(assetID: asset.id)
                return
            }
            await playback.claim(
                assetID: asset.id,
                forceMuted: forcesMute,
                seedDuration: nil,
                autoPlays: false,
                rewindsAtEnd: true,
                // the clip loads on the first long press or transport tap.
                // swiping a run of live photos used to fetch one motion video
                // per page, nearly all of them thrown away.
                defersItem: true
            ) {
                await makeItem()
            }
        }
        .onDisappear { playback.release(assetID: asset.id) }
    }

    private var posterURL: URL? {
        guard let client = session.client, !asset.isLocal else { return nil }
        return client.thumbnailURL(assetID: asset.id, size: "preview", cacheKey: asset.thumbhash)
    }

    private var posterFallbackURL: URL? {
        guard let client = session.client, !asset.isLocal else { return nil }
        return client.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash)
    }

    /// the paired video on device costs nothing to read; the server keeps the
    /// motion half as its own asset, addressed by the still's pairing id.
    private func makeItem() async -> AVPlayerItem? {
        if let localIdentifier,
           let item = await LocalImageLoader.shared.motionPlayerItem(
               localIdentifier: localIdentifier,
               allowsNetwork: asset.isLocal
           ) {
            return item
        }
        guard !asset.isLocal,
              let motionID = asset.livePhotoVideoId,
              let client = session.client
        else { return nil }
        let urlAsset = AVURLAsset(
            url: client.playbackURL(assetID: motionID),
            options: ["AVURLAssetHTTPHeaderFieldsKey": client.authHeaders]
        )
        return AVPlayerItem(asset: urlAsset)
    }
}

// MARK: - controls

/// transport strip for a live photo. the clip is only a couple of seconds
/// long, so the timeline is paired with frame steps: dragging cannot reliably
/// land on one picture out of the handful the scrubber spans.
struct LivePhotoControlsBar: View {
    let playback: VideoPlayback

    var body: some View {
        HStack(spacing: 10) {
            Button(action: playback.togglePlayPause) {
                Group {
                    if playback.isFailed {
                        Image(systemName: "exclamationmark.circle")
                    } else if playback.isBuffering {
                        ProgressView()
                    } else {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "livephoto")
                    }
                }
                .font(.body.weight(.semibold))
                .frame(width: 30, height: 30)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(playback.isFailed)
            .accessibilityLabel(playback.isPlaying ? "Pause Live Photo" : "Play Live Photo")
            .accessibilityIdentifier("live-photo-play-pause")

            stepButton(
                systemImage: "backward.frame.fill",
                label: "Previous frame",
                identifier: "live-photo-step-backward",
                count: -1
            )

            VideoScrubber(playback: playback, identifier: "live-photo-scrubber")

            stepButton(
                systemImage: "forward.frame.fill",
                label: "Next frame",
                identifier: "live-photo-step-forward",
                count: 1
            )

            Button {
                playback.isMuted.toggle()
            } label: {
                Image(systemName: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("live-photo-mute")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 24)
        .frame(maxWidth: 560)
        .accessibilityIdentifier("live-photo-controls")
    }

    private func stepButton(
        systemImage: String,
        label: String,
        identifier: String,
        count: Int
    ) -> some View {
        Button {
            playback.stepFrame(by: count)
        } label: {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(width: 28, height: 30)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(playback.isFailed)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}
