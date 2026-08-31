import AVFoundation
import Photos
import SwiftUI

/// the app's default ambient audio session is silenced by the ring switch.
/// claiming playback before audible video makes sound play regardless, like
/// the system photos app.
private final class ViewerAudioSession: @unchecked Sendable {
    static let shared = ViewerAudioSession()

    private let queue = DispatchQueue(
        label: "com.vexcited.imora.viewer-audio-session",
        qos: .userInitiated
    )
    private var isPlaybackCategoryConfigured = false

    func activateForPlayback() {
        queue.async { [weak self] in
            guard let self else { return }
            let audioSession = AVAudioSession.sharedInstance()
            if !self.isPlaybackCategoryConfigured {
                do {
                    try audioSession.setCategory(.playback, mode: .moviePlayback)
                    self.isPlaybackCategoryConfigured = true
                } catch {
                    return
                }
            }
            if #available(iOS 27.0, *) {
                audioSession.activate(options: []) { _, _ in }
            } else {
                try? audioSession.setActive(true, options: [])
            }
        }
    }
}

private func activatePlaybackAudioSession() {
    ViewerAudioSession.shared.activateForPlayback()
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
    /// the clip has been asked to move at least once. a live photo shows its
    /// still until this flips, and again once the clip runs out - the still is
    /// not video frame zero, so deriving this from the position would swap the
    /// picture underneath anyone stepping back to the start.
    private(set) var isEngaged = false
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
    /// live photos return to their still once the clip ends instead of holding
    /// the last frame, which is what makes the page look like a photo again.
    @ObservationIgnored private var rewindsAtEnd = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    /// one frame of the current item, read off its video track. the 30fps
    /// assumption only stands until that load lands.
    @ObservationIgnored private var frameInterval = 1.0 / 30
    @ObservationIgnored private var wasPlayingBeforeScrub = false
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var pendingSeekSeconds: Double?
    /// deferred item factory, held until the first engagement. live photos
    /// claim on every page-on, and building the item eagerly fetched the
    /// motion clip for clips that are almost never played.
    @ObservationIgnored private var pendingItemMaker: (@MainActor () async -> AVPlayerItem?)?
    /// a release keeps the player alive for a moment so a transient page
    /// bounce can reclaim it in place instead of restarting the clip.
    @ObservationIgnored private var releaseTask: Task<Void, Never>?
    @ObservationIgnored private var resumesOnReclaim = false

    /// `autoPlays` is false for live photos: their page opens on the still and
    /// only moves once the viewer asks it to. `defersItem` goes further and
    /// waits for the first engagement before even creating the player item,
    /// so paging across live photos costs no clip fetches at all.
    func claim(
        assetID: String,
        forceMuted: Bool,
        seedDuration: Double?,
        autoPlays: Bool = true,
        rewindsAtEnd: Bool = false,
        defersItem: Bool = false,
        makeItem: @escaping @MainActor () async -> AVPlayerItem?
    ) async {
        if ownerID == assetID {
            // the same page re-claims when its mute flag flips, e.g. a context
            // preview committing to the full viewer, or right after a resize
            // bounced it out of the lazy viewport and released transiently.
            releaseTask?.cancel()
            releaseTask = nil
            forcesMute = forceMuted
            applyMute()
            let resumes = resumesOnReclaim
            resumesOnReclaim = false
            if resumes, !isPlaying {
                if !forceMuted, !isMuted { activatePlaybackAudioSession() }
                player?.play()
            } else if !forceMuted, !isMuted, isPlaying {
                activatePlaybackAudioSession()
            }
            return
        }
        generation &+= 1
        let gen = generation
        teardown()
        ownerID = assetID
        forcesMute = forceMuted
        self.rewindsAtEnd = rewindsAtEnd
        if let seedDuration { duration = seedDuration }
        if defersItem, !autoPlays {
            pendingItemMaker = makeItem
            return
        }
        let item = await makeItem()
        guard gen == generation, !Task.isCancelled else { return }
        guard let item else {
            ownerID = nil
            return
        }
        install(item, generation: gen)
        guard autoPlays else { return }
        if !forceMuted, !isMuted { activatePlaybackAudioSession() }
        player?.play()
    }

    private func install(_ item: AVPlayerItem, generation gen: Int) {
        let player = AVPlayer(playerItem: item)
        self.player = player
        applyMute()
        attachObservers(to: player, item: item)
        // frame stepping is the only consumer, so the track load trails the
        // first frame instead of delaying it.
        Task { [weak self] in
            guard let interval = await Self.frameInterval(of: item) else { return }
            guard let self, self.generation == gen else { return }
            self.frameInterval = interval
        }
    }

    /// builds the deferred item on first engagement. the still stays on
    /// screen and the bar shows buffering until the clip is ready.
    private func engagePendingItem(thenPlays: Bool) {
        guard let maker = pendingItemMaker else { return }
        pendingItemMaker = nil
        isBuffering = true
        let gen = generation
        Task { [weak self] in
            let item = await maker()
            guard let self, self.generation == gen else { return }
            self.isBuffering = false
            guard let item else {
                self.isFailed = true
                return
            }
            self.install(item, generation: gen)
            guard thenPlays else { return }
            self.isEngaged = true
            if !self.forcesMute, !self.isMuted { activatePlaybackAudioSession() }
            self.player?.play()
        }
    }

    /// a rotation resize can bounce the active page out of the lazy
    /// container's viewport for a frame, and tearing down there is what used
    /// to restart a playing video. pause right away so a real departure never
    /// leaks audio, then keep the player briefly so the same page reclaiming
    /// resumes where it was.
    func release(assetID: String) {
        guard ownerID == assetID else { return }
        resumesOnReclaim = resumesOnReclaim || isPlaying
        player?.pause()
        releaseTask?.cancel()
        let gen = generation
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled,
                  generation == gen, ownerID == assetID
            else { return }
            releaseTask = nil
            generation &+= 1
            teardown()
            ownerID = nil
        }
    }

    func togglePlayPause() {
        guard !isFailed else { return }
        guard let player else {
            engagePendingItem(thenPlays: true)
            return
        }
        if isPlaying {
            player.pause()
        } else {
            isEngaged = true
            if duration > 0, currentTime >= duration - 0.1 {
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                currentTime = 0
            }
            if !forcesMute, !isMuted { activatePlaybackAudioSession() }
            player.play()
        }
    }

    /// pauses and moves exactly one picture, so a live photo can be walked
    /// frame by frame. deliberately not `AVPlayerItem.step(byCount:)`: that
    /// snaps to the next sync sample, which on a real clip skips several
    /// frames at a time. a zero-tolerance seek decodes to the exact time.
    func stepFrame(by count: Int) {
        guard !isFailed else { return }
        // a deferred clip has no frames to step yet; load it parked so the
        // controls come alive without playing.
        guard player != nil else {
            engagePendingItem(thenPlays: false)
            return
        }
        guard let player, duration > 0 else { return }
        isEngaged = true
        player.pause()
        let target = min(max(currentTime + Double(count) * frameInterval, 0), duration)
        currentTime = target
        pendingSeekSeconds = target
        pumpSeek()
    }

    func beginScrubbing() {
        guard !isScrubbing else { return }
        isScrubbing = true
        isEngaged = true
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

    private nonisolated static func frameInterval(of item: AVPlayerItem) async -> Double? {
        guard let track = try? await item.asset.loadTracks(withMediaType: .video).first,
              let rate = try? await track.load(.nominalFrameRate),
              rate > 0
        else { return nil }
        return 1 / Double(rate)
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
                guard self.rewindsAtEnd else {
                    self.currentTime = self.duration
                    return
                }
                self.player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                self.currentTime = 0
                self.isEngaged = false
            }
        }
    }

    private func teardown() {
        releaseTask?.cancel()
        releaseTask = nil
        resumesOnReclaim = false
        pendingItemMaker = nil
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        itemStatusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        pendingSeekSeconds = nil
        isSeeking = false
        rewindsAtEnd = false
        frameInterval = 1.0 / 30
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        isPlaying = false
        isBuffering = false
        isFailed = false
        isScrubbing = false
        isEngaged = false
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
    let onMediaReady: () -> Void
    let ownsLaunchMedia: Bool
    let launchMediaBridge: AssetViewerLaunchMediaBridge
    let openingMediaImage: UIImage?
    let allowsDoubleTapZoom: Bool
    let onMediaTap: () -> Void
    let onDoubleTapZoomChanged: (Bool) -> Void
    let onZoomInteractionStarted: () -> Void
    let onZoomPresentationChanged: (Bool) -> Void
    let onZoomChanged: (Bool) -> Void

    @State private var localUnavailable = false

    private var posterLocalIdentifier: String? {
        localUnavailable ? nil : deviceIdentifier
    }

    var body: some View {
        ZoomableScrollView(
            assetID: asset.id,
            contentID: "\(asset.id)#\(posterLocalIdentifier ?? "remote")",
            isActivePage: isActive,
            allowsDoubleTapZoom: allowsDoubleTapZoom,
            onMediaTap: onMediaTap,
            onDoubleTapZoomChanged: onDoubleTapZoomChanged,
            onZoomInteractionStarted: onZoomInteractionStarted,
            onZoomPresentationChanged: onZoomPresentationChanged,
            onZoomChanged: onZoomChanged
        ) {
            MediaSurfaceStack(
                assetID: asset.id,
                aspectRatio: asset.ratio,
                mode: .video,
                posterLocalIdentifier: posterLocalIdentifier,
                posterURL: posterURL,
                posterFallbackURL: posterFallbackURL,
                thumbhash: asset.thumbhash,
                playback: playback,
                onPosterReady: onMediaReady,
                onPosterUnavailable: {
                    localUnavailable = true
                }
            )
            .modifier(
                AssetViewerLaunchMediaModifier(
                    asset: asset,
                    openingImage: openingMediaImage,
                    ownsLaunchMedia: ownsLaunchMedia,
                    bridge: launchMediaBridge
                )
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

/// what the still underneath means for a given page. a video's poster is only
/// a placeholder, while a live photo's still is the asset itself and stays
/// visible whenever the clip is parked at its start.
enum MediaSurfaceMode {
    case video
    case livePhoto
}

/// hosted inside the zoom container, so it reads the playback observable
/// itself - the container only reassigns its root when the content id
/// changes, and the video surface has to appear without that.
struct MediaSurfaceStack: View {
    let assetID: String
    let aspectRatio: Double
    let mode: MediaSurfaceMode
    let posterLocalIdentifier: String?
    let posterURL: URL?
    let posterFallbackURL: URL?
    let thumbhash: String?
    let playback: VideoPlayback
    var onPosterReady: (() -> Void)?
    /// only a live photo needs this: its still is the asset, so losing the
    /// device copy would leave an empty page rather than a stale poster.
    var onPosterUnavailable: (() -> Void)?

    /// a live photo shows its own still until the clip actually moves, so the
    /// page renders full-resolution pixels rather than a video frame at rest.
    private var showsVideo: Bool {
        guard playback.ownerID == assetID, playback.player != nil else { return false }
        switch mode {
        case .video:
            return true
        case .livePhoto:
            return playback.isEngaged
        }
    }

    var body: some View {
        AssetViewerFittedMedia(aspectRatio: aspectRatio) {
            ZStack {
                if let posterLocalIdentifier {
                    LocalPhotoImage(
                        localIdentifier: posterLocalIdentifier,
                        targetPixelSize: pagePixelSize,
                        fallbackTargetPixelSize: 640,
                        fallbackRequestContentMode: .aspectFit,
                        requestContentMode: .aspectFit,
                        contentMode: .fill,
                        onUnavailable: { onPosterUnavailable?() },
                        onReady: { onPosterReady?() }
                    )
                } else if let posterURL {
                    RemoteImage(
                        url: posterURL,
                        targetPixelSize: pagePixelSize,
                        thumbhash: thumbhash,
                        fallbackURL: posterFallbackURL,
                        fallbackTargetPixelSize: 640,
                        contentMode: .fill,
                        onReady: { onPosterReady?() }
                    )
                }
                if showsVideo, let player = playback.player {
                    VideoPlayerSurface(
                        player: player,
                        onReady: { onPosterReady?() }
                    )
                }
            }
        }
        .clipped()
    }
}

/// bare video layer with no transport chrome. hidden until the first frame is
/// ready, then fades over the poster rather than popping in mid-render.
struct VideoPlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let onReady: () -> Void

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }

        private var readyObservation: NSKeyValueObservation?
        private var hasReportedReady = false
        private var hasScheduledReadyReport = false
        private var isFadingIn = false
        private var onReady: () -> Void = {}

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil,
                  !isFadingIn,
                  let playerLayer = layer as? AVPlayerLayer,
                  playerLayer.isReadyForDisplay
            else { return }
            scheduleReadyReport(for: playerLayer)
        }

        func configure(player: AVPlayer, onReady: @escaping () -> Void) {
            guard let playerLayer = layer as? AVPlayerLayer else { return }
            self.onReady = onReady
            if playerLayer.player !== player {
                readyObservation = nil
                hasReportedReady = false
                hasScheduledReadyReport = false
                isFadingIn = false
                playerLayer.player = player
            }
            guard !playerLayer.isReadyForDisplay else {
                guard !isFadingIn else { return }
                alpha = 1
                scheduleReadyReport(for: playerLayer)
                return
            }
            guard readyObservation == nil else { return }
            alpha = 0
            readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, change in
                guard change.newValue == true else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.alpha == 0 else { return }
                    self.readyObservation = nil
                    self.isFadingIn = true
                    UIView.animate(withDuration: 0.18) {
                        self.alpha = 1
                    } completion: { [weak self] finished in
                        guard let self else { return }
                        self.isFadingIn = false
                        guard finished,
                              self.window != nil,
                              let playerLayer = self.layer as? AVPlayerLayer,
                              playerLayer.isReadyForDisplay
                        else { return }
                        self.reportReady()
                    }
                }
            }
        }

        private func scheduleReadyReport(for playerLayer: AVPlayerLayer) {
            guard !hasReportedReady,
                  !hasScheduledReadyReport,
                  let expectedPlayer = playerLayer.player
            else { return }
            hasScheduledReadyReport = true
            Task { @MainActor [weak self, weak expectedPlayer] in
                await Task.yield()
                guard let self else { return }
                self.hasScheduledReadyReport = false
                guard self.window != nil,
                      let expectedPlayer,
                      let currentLayer = self.layer as? AVPlayerLayer,
                      currentLayer.player === expectedPlayer,
                      currentLayer.isReadyForDisplay,
                      !self.isFadingIn
                else { return }
                self.reportReady()
            }
        }

        private func reportReady() {
            guard !hasReportedReady else { return }
            hasReportedReady = true
            onReady()
        }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.backgroundColor = .clear
        let layer = view.layer as? AVPlayerLayer
        layer?.videoGravity = .resizeAspect
        view.configure(player: player, onReady: onReady)
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        uiView.configure(player: player, onReady: onReady)
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
struct VideoScrubber: View {
    let playback: VideoPlayback
    var identifier = "video-scrubber"

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
        .accessibilityIdentifier(identifier)
    }
}

func videoTimeLabel(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}
