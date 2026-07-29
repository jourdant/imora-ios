import SwiftUI
import AVKit

nonisolated enum AssetChange {
    case favorite(String, Bool)
    case removed(String)
}

struct AssetViewerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session

    let onChange: (AssetChange) -> Void

    @State private var assets: [Asset]
    @State private var currentIndex: Int
    @State private var chromeVisible = true
    @State private var showInfo = false
    @State private var dragOffset: CGFloat = 0

    init(assets: [Asset], initialIndex: Int, onChange: @escaping (AssetChange) -> Void) {
        _assets = State(initialValue: assets)
        _currentIndex = State(initialValue: initialIndex)
        self.onChange = onChange
    }

    private var current: Asset? {
        assets.indices.contains(currentIndex) ? assets[currentIndex] : nil
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - Double(min(abs(dragOffset) / 600, 0.6)))
                .ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(assets.indices, id: \.self) { index in
                    AssetPage(asset: assets[index], isActive: index == currentIndex)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: dragOffset)
            .scaleEffect(1 - min(abs(dragOffset) / 2000, 0.15))
            .simultaneousGesture(dismissDrag)
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
            }

            if chromeVisible {
                chrome
            }
        }
        .statusBarHidden(!chromeVisible)
        .sheet(isPresented: $showInfo) {
            if let current {
                AssetInfoSheet(asset: current)
                    .presentationDetents([.medium, .large])
                    .presentationBackground(.regularMaterial)
            }
        }
    }

    // MARK: - chrome

    @ViewBuilder private var chrome: some View {
        VStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.glass)
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
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.glass)
            }
            .padding(.horizontal, 16)

            Spacer()

            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 6) {
                    chromeButton(current?.isFavorite == true ? "heart.fill" : "heart") {
                        Task { await toggleFavorite() }
                    }
                    .foregroundStyle(current?.isFavorite == true ? .red : .primary)

                    chromeButton("info.circle") { showInfo = true }
                        .accessibilityIdentifier("viewer-info")

                    if let current, let client = session.client {
                        ShareLink(item: SharedAssetFile(client: client, asset: current), preview: SharePreview(current.localDate.formatted(date: .abbreviated, time: .omitted))) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.body)
                                .frame(width: 52, height: 44)
                        }
                        .buttonStyle(.plain)
                    }

                    chromeButton("trash") {
                        Task { await trash() }
                    }
                    .foregroundStyle(.red)
                }
                .padding(.horizontal, 10)
                .glassEffect(.regular, in: .capsule)
            }
            .padding(.bottom, 12)
        }
        .foregroundStyle(.white)
        .transition(.opacity)
    }

    private func chromeButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body)
                .frame(width: 52, height: 44)
        }
        .buttonStyle(.plain)
    }

    // MARK: - gestures

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) * 1.2 else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                if abs(dragOffset) > 140 || abs(value.predictedEndTranslation.height) > 500 {
                    dismiss()
                } else {
                    withAnimation(.spring(duration: 0.3)) { dragOffset = 0 }
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
        guard let client = session.client, let asset = current else { return }
        try? await client.trashAssets(ids: [asset.id])
        onChange(.removed(asset.id))
        removeCurrent()
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

// MARK: - single page

private struct AssetPage: View {
    @Environment(SessionStore.self) private var session
    let asset: Asset
    let isActive: Bool

    var body: some View {
        if asset.isVideo {
            VideoPage(asset: asset, isActive: isActive)
        } else if let client = session.client {
            ZoomableScrollView {
                RemoteImage(
                    url: client.thumbnailURL(assetID: asset.id, size: "preview"),
                    targetPixelSize: 2048,
                    thumbhash: asset.thumbhash,
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
    @ViewBuilder let content: Content

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 6
        scrollView.minimumZoomScale = 1
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        let hosted = context.coordinator.hostingController
        hosted.rootView = AnyView(content)
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
        context.coordinator.hostingController.rootView = AnyView(content)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let hostingController = UIHostingController<AnyView>(rootView: AnyView(EmptyView()))

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            hostingController.view
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > 1 {
                scrollView.setZoomScale(1, animated: true)
            } else {
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
