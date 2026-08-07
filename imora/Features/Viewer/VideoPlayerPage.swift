import AVFoundation
import SwiftUI

/// the app's default ambient audio session is silenced by the ring switch.
/// claiming playback before audible video makes sound play regardless, like
/// the system photos app.
private func activatePlaybackAudioSession() {
    let audioSession = AVAudioSession.sharedInstance()
    try? audioSession.setCategory(.playback, mode: .moviePlayback)
    try? audioSession.setActive(true)
}

/// single playback engine for the viewer. the active video page claims it and
/// the screen's control bar drives it, so paging can never leave two videos
/// audible and the controls live outside the pager where scrubbing cannot
/// fight the horizontal swipe.
@MainActor @Observable
final class VideoPlayback {
    private(set) var ownerID: String?
    private(set) var player: AVPlayer?
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var isFailed = false
    private(set) var isScrubbing = false
    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0

    /// user toggle, kept across pages for the viewer's lifetime.
    var isMuted = false {
        didSet {
            guard oldValue != isMuted else { return }
            applyMute()
            if !isMuted { activatePlaybackAudioSession() }
        }
    }

    /// context previews force silence regardless of the user toggle.
    @ObservationIgnored private var forcesMute = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var wasPlayingBeforeScrub = false
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var pendingSeekSeconds: Double?

    func claim(
        assetID: String,
        forceMuted: Bool,
        seedDuration: Double?,
        makeItem: @MainActor () async -> AVPlayerItem?
    ) async {
        if ownerID == assetID {
            // the same page re-claims when its mute flag flips, e.g. a context
            // preview committing to the full viewer.
            forcesMute = forceMuted
            applyMute()
            if !forceMuted, !isMuted { activatePlaybackAudioSession() }
            return
        }
        generation &+= 1
        let gen = generation
        teardown()
        ownerID = assetID
        forcesMute = forceMuted
        if let seedDuration { duration = seedDuration }
        let item = await makeItem()
        guard gen == generation, !Task.isCancelled else { return }
        guard let item else {
            ownerID = nil
            return
        }
        let player = AVPlayer(playerItem: item)
        self.player = player
        applyMute()
        attachObservers(to: player, item: item)
        if !forceMuted, !isMuted { activatePlaybackAudioSession() }
        player.play()
    }

    func release(assetID: String) {
        guard ownerID == assetID else { return }
        generation &+= 1
        teardown()
        ownerID = nil
    }

    func togglePlayPause() {
        guard let player, !isFailed else { return }
        if isPlaying {
            player.pause()
        } else {
            if duration > 0, currentTime >= duration - 0.1 {
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                currentTime = 0
            }
            if !forcesMute, !isMuted { activatePlaybackAudioSession() }
            player.play()
        }
    }

    func beginScrubbing() {
        guard !isScrubbing else { return }
        isScrubbing = true
        wasPlayingBeforeScrub = isPlaying
        player?.pause()
    }

    func scrub(to seconds: Double) {
        guard duration > 0 else { return }
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        pendingSeekSeconds = clamped
        pumpSeek()
    }

    func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        guard wasPlayingBeforeScrub, let player else { return }
        if !forcesMute, !isMuted { activatePlaybackAudioSession() }
        player.play()
    }

    /// seeks are serialized and intermediate targets dropped so a fast drag
    /// lands on the last position instead of replaying every sample.
    private func pumpSeek() {
        guard !isSeeking, let player, let target = pendingSeekSeconds else { return }
        pendingSeekSeconds = nil
        isSeeking = true
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSeeking = false
                self.pumpSeek()
            }
        }
    }

    private func applyMute() {
        player?.isMuted = forcesMute || isMuted
    }

    private func attachObservers(to player: AVPlayer, item: AVPlayerItem) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing, !self.isSeeking, self.pendingSeekSeconds == nil
                else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                self.currentTime = seconds
            }
        }

        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = status != .paused
                self.isBuffering = status == .waitingToPlayAtSpecifiedRate
            }
        }

        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            let seconds = item.duration.seconds
            Task { @MainActor [weak self] in
                guard let self else { return }
                if status == .failed {
                    self.isFailed = true
                    self.isBuffering = false
                }
                if status == .readyToPlay, seconds.isFinite, seconds > 0 {
                    self.duration = seconds
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = self.duration
            }
        }
    }

    private func teardown() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        itemStatusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        pendingSeekSeconds = nil
        isSeeking = false
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        isPlaying = false
        isBuffering = false
        isFailed = false
        isScrubbing = false
        duration = 0
        currentTime = 0
    }
}

// MARK: - page

/// video page built from a bare player layer inside the shared zoom container,
/// so videos pinch and double-tap exactly like photos. the poster paints the
/// page while the item loads and stays under the letterboxed video.
struct VideoPlayerPage: View {
    @Environment(SessionStore.self) private var session
    let asset: Asset
    let deviceIdentifier: String?
    let isActive: Bool
    let forcesMute: Bool
    let playback: VideoPlayback
    let onZoomChanged: (Bool) -> Void

    var body: some View {
        ZoomableScrollView(contentID: asset.id, onZoomChanged: onZoomChanged) {
            VideoSurfaceStack(
                assetID: asset.id,
                posterLocalIdentifier: deviceIdentifier,
                posterURL: posterURL,
                posterFallbackURL: posterFallbackURL,
                thumbhash: asset.thumbhash,
                playback: playback
            )
        }
        .task(id: "\(asset.id):\(isActive):\(forcesMute)") {
            guard isActive else {
                playback.release(assetID: asset.id)
                return
            }
            await playback.claim(
                assetID: asset.id,
                forceMuted: forcesMute,
                seedDuration: asset.duration.map { Double($0) / 1000 }
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

    /// the paired device copy is free; when it cannot be served the page falls
    /// back to the server stream instead of spinning forever. device-only
    /// assets may pull from icloud since they have nowhere else to go.
    private func makeItem() async -> AVPlayerItem? {
        if let deviceIdentifier,
           let item = await LocalImageLoader.shared.playerItem(
               localIdentifier: deviceIdentifier,
               allowsNetwork: asset.isLocal
           ) {
            return item
        }
        guard !asset.isLocal, let client = session.client else { return nil }
        let urlAsset = AVURLAsset(
            url: client.playbackURL(assetID: asset.id),
            options: ["AVURLAssetHTTPHeaderFieldsKey": client.authHeaders]
        )
        return AVPlayerItem(asset: urlAsset)
    }
}

/// hosted inside the zoom container, so it reads the playback observable
/// itself - the container only reassigns its root when the content id
/// changes, and the video surface has to appear without that.
private struct VideoSurfaceStack: View {
    let assetID: String
    let posterLocalIdentifier: String?
    let posterURL: URL?
    let posterFallbackURL: URL?
    let thumbhash: String?
    let playback: VideoPlayback

    var body: some View {
        ZStack {
            if let posterLocalIdentifier {
                LocalPhotoImage(
                    localIdentifier: posterLocalIdentifier,
                    targetPixelSize: pagePixelSize,
                    fallbackTargetPixelSize: 640,
                    contentMode: .fit
                )
            } else if let posterURL {
                RemoteImage(
                    url: posterURL,
                    targetPixelSize: pagePixelSize,
                    thumbhash: thumbhash,
                    fallbackURL: posterFallbackURL,
                    fallbackTargetPixelSize: 640,
                    contentMode: .fit
                )
            }
            if playback.ownerID == assetID, let player = playback.player {
                VideoPlayerSurface(player: player)
            }
        }
    }
}

/// bare video layer with no transport chrome. hidden until the first frame is
/// ready, then fades over the poster rather than popping in mid-render.
private struct VideoPlayerSurface: UIViewRepresentable {
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
        layer?.videoGravity = .resizeAspect
        view.fadeInOnFirstFrame()
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        (uiView.layer as? AVPlayerLayer)?.player = player
    }
}

// MARK: - controls

/// photos style transport strip shown with the viewer chrome.
struct VideoControlsBar: View {
    let playback: VideoPlayback

    var body: some View {
        HStack(spacing: 12) {
            Button(action: playback.togglePlayPause) {
                Group {
                    if playback.isFailed {
                        Image(systemName: "exclamationmark.circle")
                    } else if playback.isBuffering {
                        ProgressView()
                    } else {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    }
                }
                .font(.body.weight(.semibold))
                .frame(width: 30, height: 30)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(playback.isFailed)
            .accessibilityIdentifier("video-play-pause")

            Text(videoTimeLabel(playback.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            VideoScrubber(playback: playback)

            Text("-" + videoTimeLabel(max(0, playback.duration - playback.currentTime)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                playback.isMuted.toggle()
            } label: {
                Image(systemName: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("video-mute")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 24)
        .frame(maxWidth: 560)
        .accessibilityIdentifier("video-controls")
    }
}

/// drag anywhere on the track to seek; the bar thickens while scrubbing like
/// the system players.
private struct VideoScrubber: View {
    let playback: VideoPlayback

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = playback.duration > 0
                ? min(max(playback.currentTime / playback.duration, 0), 1)
                : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.2))
                Capsule().fill(Color.primary.opacity(0.9))
                    .frame(width: width * fraction)
            }
            .frame(height: playback.isScrubbing ? 12 : 6)
            .frame(width: width, height: geometry.size.height)
            .animation(.smooth(duration: 0.18), value: playback.isScrubbing)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard width > 0 else { return }
                        playback.beginScrubbing()
                        playback.scrub(to: Double(value.location.x / width) * playback.duration)
                    }
                    .onEnded { _ in
                        playback.endScrubbing()
                    }
            )
        }
        .frame(height: 30)
        .accessibilityIdentifier("video-scrubber")
    }
}

private func videoTimeLabel(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}
