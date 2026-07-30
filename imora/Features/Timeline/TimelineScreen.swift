import SwiftUI

private struct TimelineScrollState: Equatable {
    let fraction: CGFloat
    let scrollableHeight: CGFloat
}

/// scroll-driven values live here instead of screen @state so per-frame
/// updates only re-render the scrubber overlay, never the whole grid body.
@Observable @MainActor
private final class ScrubberState {
    var fraction: CGFloat = 0
    var scrollableHeight: CGFloat = 0
    var visibleMonth: String?
    var isScrubbing = false

    func update(with state: TimelineScrollState) {
        if scrollableHeight != state.scrollableHeight {
            scrollableHeight = state.scrollableHeight
        }
        guard !isScrubbing, fraction != state.fraction else { return }
        fraction = state.fraction
    }
}

/// reusable bucketed photo grid, the workhorse behind most screens.
struct TimelineScreen<Header: View>: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    let filter: TimelineFilter
    var emptyIcon = "photo.on.rectangle"
    var emptyMessage = "No photos yet"
    var showsLargeTitle = true
    let header: Header

    @State private var model: TimelineModel
    @State private var selection = Set<String>()
    @State private var isSelecting = false
    @State private var viewer = ViewerPresentation()
    @State private var scrubberVisible = false
    /// stays true a little longer than the fade so a finger reaching for the
    /// thumb still grabs it instead of scrolling the grid underneath.
    @State private var scrubberGrabbable = false
    @State private var scrubberHideTask: Task<Void, Never>?
    @State private var scrub = ScrubberState()
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var pendingAlbumAssets: [String]?
    @State private var columnCount = 3
    @State private var pinchBaseColumns: Int?
    @Namespace private var zoomNamespace

    init(
        title: String,
        filter: TimelineFilter,
        emptyIcon: String = "photo.on.rectangle",
        emptyMessage: String = "No photos yet",
        showsLargeTitle: Bool = true,
        @ViewBuilder header: () -> Header = { EmptyView() }
    ) {
        self.title = title
        self.filter = filter
        self.emptyIcon = emptyIcon
        self.emptyMessage = emptyMessage
        self.showsLargeTitle = showsLargeTitle
        self.header = header()
        _model = State(initialValue: TimelineModel(filter: filter))
    }

    private func tileSide(for width: CGFloat) -> CGFloat {
        (width - CGFloat(columnCount - 1) * 2) / CGFloat(columnCount)
    }

    /// pads the scroll bottom so the last month header can reach the top of
    /// the viewport. without it a short final month is unreachable by the
    /// scrubber because the scroll stops at the previous month.
    private func endPadding(side: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        guard model.contentHeight(tileSide: side) > viewportHeight else { return 0 }
        return max(0, (viewportHeight - model.tailHeight(tileSide: side)).rounded())
    }

    var body: some View {
        @Bindable var viewer = viewer

        GeometryReader { geometry in
            let side = tileSide(for: geometry.size.width)

            ScrollView {
                LazyVStack(spacing: 0) {
                    header

                    ForEach(model.rows) { row in
                        rowView(row, side: side)
                            .id(row.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.bottom, (isSelecting ? 90 : 0) + endPadding(side: side, viewportHeight: geometry.size.height))
            }
            .scrollPosition($scrollPosition)
            .scrollIndicators(.hidden)
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { rowIDs in
                let month = rowIDs.first.flatMap { model.monthByRowID[$0] }
                guard month != scrub.visibleMonth else { return }
                // deferred one tick so the write never lands in the same
                // frame as the scroll pass that produced it.
                Task { @MainActor in
                    if month != scrub.visibleMonth { scrub.visibleMonth = month }
                }
            }
            .simultaneousGesture(
                pinchGesture(
                    viewportWidth: geometry.size.width,
                    viewportHeight: geometry.size.height
                )
            )
            .onScrollGeometryChange(for: TimelineScrollState.self) { scroll in
                // rounded so sub point layout noise dedupes to equal states.
                let scrollable = max(0, (scroll.contentSize.height - scroll.containerSize.height).rounded())
                let rawFraction = scrollable > 0 ? scroll.contentOffset.y / scrollable : 0
                let fraction = (min(1, max(0, rawFraction)) * 1_000).rounded() / 1_000
                return TimelineScrollState(
                    fraction: fraction,
                    scrollableHeight: scrollable
                )
            } action: { _, state in
                scrub.update(with: state)
            }
            .onScrollPhaseChange { _, newPhase in
                if newPhase == .idle {
                    scheduleScrubberHide()
                } else {
                    showScrubber()
                }
            }
            .overlay(alignment: .trailing) {
                if model.rows.count > 30 && !viewer.isTransitioning {
                    TimelineScrubber(
                        viewportHeight: geometry.size.height,
                        scrub: scrub,
                        visible: scrubberVisible,
                        grabbable: scrubberGrabbable
                    ) { offset in
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            scrollPosition.scrollTo(y: offset)
                        }
                    } onScrubbingChanged: { scrubbing in
                        if scrubbing {
                            showScrubber()
                        } else {
                            scheduleScrubberHide()
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(showsLargeTitle ? .large : .inline)
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { exitSelection() }
                }
            }
        }
        .overlay { overlayState }
        .overlay(alignment: .bottom) {
            if isSelecting {
                SelectionActionBar(
                    count: selection.count,
                    filter: filter,
                    onFavorite: { await applyFavorite() },
                    onArchive: { await applyVisibility(filter.visibility == .archive ? .timeline : .archive) },
                    onTrash: { await applyTrash() },
                    onRestore: filter.isTrashed == true ? { await applyRestore() } : nil,
                    onAddToAlbum: { pendingAlbumAssets = Array(selection) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: isSelecting)
        .refreshable { await model.refresh() }
        .task {
            if let client = session.client {
                model.attach(client)
                model.columns = columnCount
                await model.load()
            }
        }
        // full screen cover keeps the grid and its bars on screen behind the
        // zoom morph, exactly like the system photos app; a navigation push
        // slides the source bars and stalls taps after the pop settles.
        .fullScreenCover(item: $viewer.route) { route in
            AssetViewerScreen(
                assets: route.assets,
                initialIndex: route.initialIndex,
                presentationID: route.id,
                zoomNamespace: zoomNamespace,
                onDismissed: { finishViewer(route.id) }
            ) { change in
                handleViewerChange(change)
            }
        }
        .sheet(item: $pendingAlbumAssets) { ids in
            AlbumPickerSheet(assetIDs: ids) {
                exitSelection()
            }
        }
    }

    // MARK: - rows

    @ViewBuilder private func rowView(_ row: TimelineRow, side: CGFloat) -> some View {
        switch row {
        case .monthHeader(_, let monthTitle):
            Text(monthTitle)
                .font(.title2.weight(.bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .frame(height: 56, alignment: .bottomLeading)

        case .dayHeader(_, let dayTitle, let assetIDs):
            HStack {
                Text(dayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if isSelecting {
                    let allSelected = assetIDs.allSatisfy { selection.contains($0) }
                    Button {
                        if allSelected {
                            selection.subtract(assetIDs)
                        } else {
                            selection.formUnion(assetIDs)
                        }
                    } label: {
                        Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(allSelected ? Color.accentColor : .secondary)
                            .contentTransition(.symbolEffect(.replace))
                            .animation(.snappy(duration: 0.22), value: allSelected)
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 36)

        case .tiles(_, let assets):
            HStack(spacing: 2) {
                ForEach(assets) { asset in
                    tile(asset)
                        .frame(width: side, height: side)
                }
                if assets.count < columnCount {
                    Spacer(minLength: 0)
                }
            }
            .padding(.bottom, 2)

        case .placeholder(_, let bucketID, let tileRows):
            PlaceholderGrid(tileRows: tileRows, columns: columnCount, side: side)
                // debounced rows: a synchronous rebuild here changes the
                // bottom padding inside the scroll pass that revealed the
                // placeholder, re entering the geometry callbacks same frame.
                .onAppear { Task { await model.loadBucket(bucketID, immediateRows: false) } }
        }
    }

    @ViewBuilder private func tile(_ asset: Asset) -> some View {
        AssetTile(asset: asset)
            .overlay(alignment: .topLeading) {
                if isSelecting {
                    Image(systemName: selection.contains(asset.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, selection.contains(asset.id) ? Color.accentColor : .black.opacity(0.25))
                        .contentTransition(.symbolEffect(.replace))
                        .animation(.snappy(duration: 0.22), value: selection.contains(asset.id))
                        .padding(6)
                }
            }
            .overlay {
                if isSelecting && selection.contains(asset.id) {
                    Rectangle().stroke(Color.accentColor, lineWidth: 3)
                }
            }
            .matchedTransitionSource(id: asset.id, in: zoomNamespace)
            .onTapGesture {
                if isSelecting {
                    toggle(asset)
                } else {
                    openViewer(at: asset)
                }
            }
            .onLongPressGesture(minimumDuration: 0.3) {
                guard !isSelecting else { return }
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                isSelecting = true
                selection.insert(asset.id)
            }
    }

    @ViewBuilder private var overlayState: some View {
        if model.isLoading && model.sections.isEmpty {
            ProgressView()
        } else if let error = model.loadError, model.sections.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { Task { await model.load() } }
                    .buttonStyle(.glass)
            }
        } else if model.isEmpty {
            ContentUnavailableView(emptyMessage, systemImage: emptyIcon)
        }
    }

    // MARK: - gestures

    private func pinchGesture(viewportWidth: CGFloat, viewportHeight: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBaseColumns ?? columnCount
                pinchBaseColumns = base
                // zooming in shows fewer, larger tiles.
                let target = min(5, max(2, Int((Double(base) / value.magnification).rounded())))
                guard target != columnCount else { return }

                let preservedFraction = scrub.fraction
                let generator = UISelectionFeedbackGenerator()
                generator.selectionChanged()

                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    columnCount = target
                    model.columns = target
                }

                let newSide = (viewportWidth - CGFloat(target - 1) * 2) / CGFloat(target)
                let contentHeight = model.contentHeight(tileSide: newSide)
                    + endPadding(side: newSide, viewportHeight: viewportHeight)
                // one tick later so content size and offset never both
                // change inside the same gesture frame.
                let offset = preservedFraction * max(0, contentHeight - viewportHeight)
                Task { @MainActor in
                    var scrollTransaction = Transaction()
                    scrollTransaction.disablesAnimations = true
                    withTransaction(scrollTransaction) {
                        scrollPosition.scrollTo(y: offset)
                    }
                }
            }
            .onEnded { _ in pinchBaseColumns = nil }
    }

    // MARK: - selection

    private func toggle(_ asset: Asset) {
        if selection.contains(asset.id) {
            selection.remove(asset.id)
            if selection.isEmpty { isSelecting = false }
        } else {
            selection.insert(asset.id)
        }
    }

    private func exitSelection() {
        selection.removeAll()
        isSelecting = false
    }

    private func openViewer(at asset: Asset) {
        guard let index = model.flatAssetIndex(for: asset.id) else { return }

        // no transition gate: taps during a still settling dismissal must
        // start the next presentation, matching the system photos app. the
        // suspension resolves through the active viewer's completion.
        model.suspendForViewer()
        hideScrubberForViewer()
        viewer.present(assets: model.flatAssets, initialIndex: index)
    }

    private func finishViewer(_ id: UUID) {
        viewer.complete(id)
        Task {
            // let the zoom out settle before the o(library) row rebuild and
            // prefetch restart, otherwise they land on the animation's last
            // frames and read as a freeze.
            try? await Task.sleep(for: .milliseconds(400))
            guard !viewer.isTransitioning else { return }
            model.resumeAfterViewer()
        }
    }

    private func hideScrubberForViewer() {
        scrubberHideTask?.cancel()
        scrubberHideTask = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrubberVisible = false
            scrubberGrabbable = false
            scrub.isScrubbing = false
        }
    }

    private func handleViewerChange(_ change: AssetChange) {
        switch change {
        case .favorite(let id, let value):
            model.updateAssets(ids: [id]) { $0.isFavorite = value }
        case .removed(let id):
            model.removeAssets(ids: [id])
        case .localDeleted:
            // the server copy remains, so the timeline keeps the asset.
            break
        }
    }

    // MARK: - bulk actions

    private func applyFavorite() async {
        guard let client = session.client else { return }
        let ids = Array(selection)
        try? await client.setFavorite(ids: ids, true)
        model.updateAssets(ids: selection) { $0.isFavorite = true }
        exitSelection()
    }

    private func applyVisibility(_ value: AssetVisibility) async {
        guard let client = session.client else { return }
        try? await client.setVisibility(ids: Array(selection), value)
        model.removeAssets(ids: selection)
        exitSelection()
    }

    private func applyTrash() async {
        guard let client = session.client else { return }
        let ids = Array(selection)
        // a server delete also removes device copies when they exist. declining
        // the system dialog aborts the whole delete.
        if let backup = session.backup {
            var localIds: [String] = []
            for id in ids {
                if let localId = await backup.localIdentifier(forRemote: id) {
                    localIds.append(localId)
                }
            }
            if !localIds.isEmpty {
                do {
                    try await PhotoLibraryService.delete(localIdentifiers: localIds)
                } catch {
                    return
                }
                backup.noteLocalDeletion(localIds)
            }
        }
        try? await client.trashAssets(ids: ids)
        model.removeAssets(ids: selection)
        exitSelection()
    }

    private func applyRestore() async {
        guard let client = session.client else { return }
        try? await client.restoreAssets(ids: Array(selection))
        model.removeAssets(ids: selection)
        exitSelection()
    }

    private func showScrubber() {
        guard !viewer.isTransitioning else { return }
        scrubberHideTask?.cancel()
        scrubberHideTask = nil
        scrubberGrabbable = true
        if reduceMotion {
            scrubberVisible = true
        } else {
            withAnimation(.easeOut(duration: 0.16)) { scrubberVisible = true }
        }
    }

    private func scheduleScrubberHide() {
        guard !viewer.isTransitioning else { return }
        scrubberHideTask?.cancel()
        scrubberHideTask = Task {
            try? await Task.sleep(for: .milliseconds(5_000))
            guard !Task.isCancelled, !scrub.isScrubbing else { return }
            if reduceMotion {
                scrubberVisible = false
            } else {
                withAnimation(.easeOut(duration: 0.2)) { scrubberVisible = false }
            }
            // grace window: grabbing the edge right after the fade revives
            // the scrubber under the finger instead of scrolling the grid.
            try? await Task.sleep(for: .milliseconds(4_000))
            guard !Task.isCancelled, !scrub.isScrubbing else { return }
            scrubberGrabbable = false
        }
    }
}

extension [String]: @retroactive Identifiable {
    public var id: String { joined(separator: ",") }
}

/// dimmed grid pattern shown while a bucket loads. fixed height by construction.
private struct PlaceholderGrid: View {
    let tileRows: Int
    let columns: Int
    let side: CGFloat

    var body: some View {
        // draw at most a screenful of visible squares; the rest is one flat block.
        let visibleRows = min(tileRows, 12)
        VStack(spacing: 2) {
            ForEach(0..<visibleRows, id: \.self) { _ in
                HStack(spacing: 2) {
                    ForEach(0..<columns, id: \.self) { _ in
                        Rectangle()
                            .fill(Color(.secondarySystemFill))
                            .frame(width: side, height: side)
                    }
                }
            }
            if tileRows > visibleRows {
                Rectangle()
                    .fill(Color(.secondarySystemFill).opacity(0.6))
                    .frame(height: CGFloat(tileRows - visibleRows) * (side + 2) - 2)
            }
        }
        .padding(.bottom, 2)
    }
}

/// glass bottom bar shown during multi-select.
private struct SelectionActionBar: View {
    let count: Int
    let filter: TimelineFilter
    let onFavorite: () async -> Void
    let onArchive: () async -> Void
    let onTrash: () async -> Void
    var onRestore: (() async -> Void)?
    let onAddToAlbum: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 4) {
                Text("\(count)")
                    .font(.headline)
                    .monospacedDigit()
                    .frame(minWidth: 32)

                Spacer(minLength: 0)

                if let onRestore {
                    barButton("arrow.uturn.backward", "Restore") { Task { await onRestore() } }
                } else {
                    barButton("heart", "Favorite") { Task { await onFavorite() } }
                    barButton(filter.visibility == .archive ? "tray.and.arrow.up" : "archivebox", "Archive") { Task { await onArchive() } }
                    barButton("rectangle.stack.badge.plus", "Album", action: onAddToAlbum)
                }
                barButton("trash", "Trash", role: .destructive) { Task { await onTrash() } }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func barButton(_ icon: String, _ label: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.body)
                Text(label)
                    .font(.caption2)
            }
            .frame(minWidth: 52)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? .red : .primary)
    }
}

/// right-edge drag scrubber backed by continuous scroll offsets.
private struct TimelineScrubber: View {
    let viewportHeight: CGFloat
    let scrub: ScrubberState
    let visible: Bool
    let grabbable: Bool
    let onJump: (CGFloat) -> Void
    let onScrubbingChanged: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var label: String?
    @State private var labelHideTask: Task<Void, Never>?
    @State private var lastMonth: String?

    private let trackTop: CGFloat = 64
    private let trackBottom: CGFloat = 82
    private let thumbHeight: CGFloat = 44

    private var trackHeight: CGFloat {
        max(1, viewportHeight - trackTop - trackBottom - thumbHeight)
    }

    private var shown: Bool { visible || scrub.isScrubbing }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // the glass thumb must actually leave the hierarchy when hidden -
            // fading it with opacity leaves the glass layer visible on screen
            // while hit testing is off, a phantom pill that ignores touches.
            if shown {
                HStack(spacing: 8) {
                    if let label {
                        Text(label)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .glassEffect(.regular, in: .capsule)
                            .accessibilityIdentifier("timeline-scrubber-label")
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94, anchor: .trailing)))
                    }

                    VStack(spacing: 1) {
                        Image(systemName: "chevron.compact.up")
                        Image(systemName: "chevron.compact.down")
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: thumbHeight)
                    .glassEffect(.regular, in: .capsule)
                    .scaleEffect(scrub.isScrubbing && !reduceMotion ? 1.12 : 1, anchor: .trailing)
                    .animation(.snappy(duration: 0.2), value: scrub.isScrubbing)
                    .padding(.trailing, 4)
                }
                .offset(y: trackTop + scrub.fraction * trackHeight)
                .transition(.opacity)
            }
        }
        .frame(width: 220, height: viewportHeight, alignment: .topTrailing)
        .overlay(alignment: .trailing) {
            Color.black.opacity(0.001)
                .frame(width: 44, height: viewportHeight)
                .contentShape(.rect)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard grabbable || scrub.isScrubbing else { return }
                            labelHideTask?.cancel()
                            if let month = scrub.visibleMonth { setLabel(month) }
                            if !scrub.isScrubbing {
                                scrub.isScrubbing = true
                                onScrubbingChanged(true)
                            }
                            // quantized and deduped so coalesced touch
                            // samples collapse to one write per frame.
                            let raw = min(1, max(0, (value.location.y - trackTop - thumbHeight / 2) / trackHeight))
                            let fraction = (raw * 1_000).rounded() / 1_000
                            guard fraction != scrub.fraction else { return }
                            scrub.fraction = fraction
                            onJump(fraction * scrub.scrollableHeight)
                        }
                        .onEnded { _ in
                            scrub.isScrubbing = false
                            onScrubbingChanged(false)
                            scheduleLabelHide()
                        }
                )
                .allowsHitTesting(grabbable || scrub.isScrubbing)
                .accessibilityIdentifier("timeline-scrubber")
        }
        .onChange(of: scrub.visibleMonth) { _, month in
            guard scrub.isScrubbing || label != nil, let month else { return }
            setLabel(month)
        }
        .onDisappear { labelHideTask?.cancel() }
    }

    private func scheduleLabelHide() {
        labelHideTask?.cancel()
        labelHideTask = Task {
            try? await Task.sleep(for: .milliseconds(3_000))
            guard !Task.isCancelled else { return }
            if reduceMotion {
                label = nil
            } else {
                withAnimation(.easeOut(duration: 0.18)) { label = nil }
            }
        }
    }

    private func setLabel(_ month: String) {
        label = month
        guard month != lastMonth else { return }
        lastMonth = month
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()
    }
}
