import SwiftUI
import AVKit

nonisolated enum AssetChange {
    case favorite(String, Bool)
    case removed(String)
    /// deleted from the device only - the server copy remains, so grids keep it.
    case localDeleted(String)
}

struct AssetViewerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(SessionStore.self) private var session

    let onChange: (AssetChange) -> Void
    let zoomNamespace: Namespace.ID?

    @State private var assets: [Asset]
    @State private var currentIndex: Int
    @State private var chromeVisible = true
    @State private var showInfo = false
    @State private var dragOffset: CGFloat = 0
    @State private var currentPageZoomed = false
    /// device copy of the current asset, when the backup index proves one exists.
    @State private var localIdentifier: String?
    @State private var downloading = false
    @State private var actionError: String?

    init(
        assets: [Asset],
        initialIndex: Int,
        zoomNamespace: Namespace.ID? = nil,
        onChange: @escaping (AssetChange) -> Void
    ) {
        _assets = State(initialValue: assets)
        _currentIndex = State(initialValue: initialIndex)
        self.zoomNamespace = zoomNamespace
        self.onChange = onChange
    }

    private var current: Asset? {
        assets.indices.contains(currentIndex) ? assets[currentIndex] : nil
    }

    @ViewBuilder var body: some View {
        // zooming out targets the currently paged asset's tile when visible.
        if let zoomNamespace, !reduceMotion {
            core.navigationTransition(.zoom(sourceID: current?.id ?? "", in: zoomNamespace))
        } else {
            core
        }
    }

    private var core: some View {
        ZStack {
            Color.black
                .opacity(1 - Double(min(abs(dragOffset) / 600, 0.6)))
                .ignoresSafeArea()
                .accessibilityIdentifier("asset-viewer")

            TabView(selection: $currentIndex) {
                ForEach(assets.indices, id: \.self) { index in
                    AssetPage(
                        asset: assets[index],
                        isActive: index == currentIndex
                    ) { isZoomed in
                        guard index == currentIndex else { return }
                        currentPageZoomed = isZoomed
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: dragOffset)
            .scaleEffect(1 - min(abs(dragOffset) / 2000, 0.15))
            .simultaneousGesture(dismissDrag)
            .onTapGesture {
                withAnimation(reduceMotion ? .linear(duration: 0.12) : .smooth(duration: 0.2)) {
                    chromeVisible.toggle()
                }
            }

            if chromeVisible {
                chrome
            }
        }
        .statusBarHidden(!chromeVisible)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .onChange(of: currentIndex) { _, _ in
            currentPageZoomed = false
            dragOffset = 0
        }
        .sheet(isPresented: $showInfo) {
            if let current {
                AssetInfoSheet(asset: current)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.regularMaterial)
                    .presentationCornerRadius(28)
            }
        }
        .task(id: current?.id) {
            localIdentifier = nil
            guard let asset = current, let backup = session.backup else { return }
            localIdentifier = await backup.localIdentifier(forRemote: asset.id)
        }
        .alert(
            actionError ?? "",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: - chrome

    @ViewBuilder private var chrome: some View {
        VStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    viewerButtonLabel("chevron.backward")
                }
                .viewerControl()
                .accessibilityIdentifier("viewer-close")

                Spacer()

                if let current {
                    VStack(spacing: 1) {
                        Text(current.localDate, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().utc())
                            .font(.subheadline.weight(.semibold))
                        Text(current.localDate, format: .dateTime.hour().minute().utc())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Menu {
                    Button {
                        Task { await archive() }
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    if localIdentifier != nil {
                        Button(role: .destructive) {
                            Task { await deleteEverywhere() }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .accessibilityIdentifier("viewer-delete")
                        Button(role: .destructive) {
                            Task { await deleteFromDevice() }
                        } label: {
                            Label("Delete from Device Only", systemImage: "iphone.slash")
                        }
                        .accessibilityIdentifier("viewer-delete-device")
                    } else if downloading {
                        Button {} label: {
                            Label("Downloading...", systemImage: "arrow.down.circle.dotted")
                        }
                        .disabled(true)
                    } else {
                        Button {
                            Task { await download() }
                        } label: {
                            Label("Download", systemImage: "arrow.down.circle")
                        }
                        .accessibilityIdentifier("viewer-download")
                    }
                } label: {
                    viewerButtonLabel("ellipsis")
                }
                .viewerControl()
                .accessibilityIdentifier("viewer-menu")
            }
            .padding(.horizontal, 16)

            Spacer()

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    chromeButton(current?.isFavorite == true ? "heart.fill" : "heart") {
                        Task { await toggleFavorite() }
                    }
                    .tint(current?.isFavorite == true ? .red : nil)

                    chromeButton("info.circle") { showInfo = true }
                        .accessibilityIdentifier("viewer-info")

                    if let current, let client = session.client {
                        ShareLink(item: SharedAssetFile(client: client, asset: current), preview: SharePreview(current.localDate.formatted(date: .abbreviated, time: .omitted))) {
                            viewerButtonLabel("square.and.arrow.up")
                        }
                        .viewerControl()
                    }

                    chromeButton("trash") {
                        Task { await trash() }
                    }
                    .tint(.red)
                    .accessibilityIdentifier("viewer-trash")
                }
            }
            .padding(.bottom, 12)
        }
        .foregroundStyle(.white)
        .transition(.opacity)
    }

    private func chromeButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            viewerButtonLabel(icon)
        }
        .viewerControl()
    }

    private func viewerButtonLabel(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 34, height: 34)
            .glassEffect(.clear.interactive(), in: .circle)
    }

    // MARK: - gestures

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !currentPageZoomed,
                      value.translation.height > 0,
                      value.translation.height > abs(value.translation.width) * 1.15
                else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                guard dragOffset > 0 else { return }
                if dragOffset > 110 || value.predictedEndTranslation.height > 360 {
                    dismiss()
                } else {
                    withAnimation(reduceMotion ? .linear(duration: 0.12) : .spring(duration: 0.28, bounce: 0.16)) {
                        dragOffset = 0
                    }
                }
            }
    }

    // MARK: - actions

    private func toggleFavorite() async {
        guard let client = session.client, let asset = current else { return }
        let newValue = !asset.isFavorite
        assets[currentIndex].isFavorite = newValue
        onChange(.favorite(asset.id, newValue))
        try? await client.setFavorite(ids: [asset.id], newValue)
    }

    private func archive() async {
        guard let client = session.client, let asset = current else { return }
        try? await client.setVisibility(ids: [asset.id], .archive)
        onChange(.removed(asset.id))
        removeCurrent()
    }

    private func trash() async {
        // a server delete also removes the device copy when one exists.
        if localIdentifier != nil {
            await deleteEverywhere()
            return
        }
        guard let client = session.client, let asset = current else { return }
        try? await client.trashAssets(ids: [asset.id])
        onChange(.removed(asset.id))
        removeCurrent()
    }

    /// device first: declining the system dialog aborts with nothing changed.
    /// after the device copy is gone the index is updated immediately, even if
    /// the server call then fails.
    private func deleteEverywhere() async {
        guard let client = session.client, let asset = current, let localId = localIdentifier else { return }
        do {
            try await PhotoLibraryService.delete(localIdentifiers: [localId])
        } catch {
            return
        }
        session.backup?.noteLocalDeletion([localId])
        localIdentifier = nil
        do {
            try await client.trashAssets(ids: [asset.id])
            onChange(.removed(asset.id))
            removeCurrent()
        } catch {
            onChange(.localDeleted(asset.id))
            actionError = "Deleted from this device, but the server copy could not be deleted."
        }
    }

    /// saves the server original into the photo library; the index pairing is
    /// recorded by the backup manager so the delete options appear right away.
    private func download() async {
        guard let asset = current, let backup = session.backup else { return }
        downloading = true
        defer { downloading = false }
        do {
            let localId = try await backup.download(asset: asset)
            if current?.id == asset.id { localIdentifier = localId }
        } catch {
            actionError = "Could not download: \(error.localizedDescription)"
        }
    }

    private func deleteFromDevice() async {
        guard let asset = current, let localId = localIdentifier else { return }
        do {
            try await PhotoLibraryService.delete(localIdentifiers: [localId])
        } catch {
            return
        }
        session.backup?.noteLocalDeletion([localId])
        localIdentifier = nil
        onChange(.localDeleted(asset.id))
    }

    private func removeCurrent() {
        guard assets.indices.contains(currentIndex) else { return }
        assets.remove(at: currentIndex)
        if assets.isEmpty {
            dismiss()
        } else if currentIndex >= assets.count {
            currentIndex = assets.count - 1
        }
    }
}

private extension View {
    func viewerControl() -> some View {
        buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
    }
}

// MARK: - single page

private struct AssetPage: View {
    @Environment(SessionStore.self) private var session
    let asset: Asset
    let isActive: Bool
    let onZoomChanged: (Bool) -> Void

    var body: some View {
        if asset.isVideo {
            VideoPage(asset: asset, isActive: isActive)
        } else if let client = session.client {
            ZoomableScrollView(onZoomChanged: onZoomChanged) {
                RemoteImage(
                    url: client.thumbnailURL(assetID: asset.id, size: "preview"),
                    targetPixelSize: 2048,
                    thumbhash: asset.thumbhash,
                    fallbackURL: client.thumbnailURL(assetID: asset.id),
                    contentMode: .fit
                )
            }
        }
    }
}

private struct VideoPage: View {
    @Environment(SessionStore.self) private var session
    let asset: Asset
    let isActive: Bool
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: isActive) {
            guard isActive else {
                player?.pause()
                return
            }
            if player == nil, let client = session.client {
                let asset = AVURLAsset(
                    url: client.playbackURL(assetID: self.asset.id),
                    options: ["AVURLAssetHTTPHeaderFieldsKey": client.authHeaders]
                )
                player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            }
            player?.play()
        }
        .onDisappear { player?.pause() }
    }
}

// MARK: - zoom container

private struct ZoomableScrollView<Content: View>: UIViewRepresentable {
    let onZoomChanged: (Bool) -> Void
    @ViewBuilder let content: Content

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 6
        scrollView.minimumZoomScale = 1
        scrollView.bounces = true
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .fast
        scrollView.isDirectionalLockEnabled = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        let hosted = context.coordinator.hostingController
        hosted.view.backgroundColor = .clear
        hosted.view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(hosted.view)
        NSLayoutConstraint.activate([
            hosted.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            hosted.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            hosted.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            hosted.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            hosted.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            hosted.view.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.hostingController.rootView = content
        context.coordinator.onZoomChanged = onZoomChanged
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content, onZoomChanged: onZoomChanged)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let hostingController: UIHostingController<Content>
        var onZoomChanged: (Bool) -> Void
        private var lastReportedZoomed = false

        init(content: Content, onZoomChanged: @escaping (Bool) -> Void) {
            hostingController = UIHostingController(rootView: content)
            self.onZoomChanged = onZoomChanged
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            hostingController.view
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let isZoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            guard isZoomed != lastReportedZoomed else { return }
            lastReportedZoomed = isZoomed
            onZoomChanged(isZoomed)
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }

            let point = gesture.location(in: hostingController.view)
            let size = CGSize(
                width: scrollView.bounds.width / 2.5,
                height: scrollView.bounds.height / 2.5
            )
            let origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
            scrollView.zoom(to: CGRect(origin: origin, size: size), animated: true)
        }
    }
}

// MARK: - share support

nonisolated struct SharedAssetFile: Transferable {
    let client: ImmichClient
    let asset: Asset

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .item) { wrapper in
            let url = wrapper.client.originalURL(assetID: wrapper.asset.id)
            var request = URLRequest(url: url)
            for (key, value) in wrapper.client.authHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            var filename = "photo"
            if let http = response as? HTTPURLResponse,
               let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
               let range = disposition.range(of: "filename=\"") {
                filename = String(disposition[range.upperBound...].prefix(while: { $0 != "\"" }))
            } else if wrapper.asset.isVideo {
                filename = "video.mov"
            } else {
                filename = "photo.jpg"
            }
            let target = FileManager.default.temporaryDirectory.appending(path: filename)
            try? FileManager.default.removeItem(at: target)
            try data.write(to: target)
            return SentTransferredFile(target)
        }
    }
}
