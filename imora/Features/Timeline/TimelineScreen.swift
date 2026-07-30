import SwiftUI

nonisolated struct ViewerContext: Identifiable, Hashable {
    let assets: [Asset]
    let index: Int
    var id: String { assets[index].id }

    static func == (lhs: ViewerContext, rhs: ViewerContext) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

private struct TimelineScrollState: Equatable {
    let fraction: CGFloat
    let scrollableHeight: CGFloat
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
    @State private var viewer: ViewerContext?
    @State private var scrubberVisible = false
    @State private var scrubberHideTask: Task<Void, Never>?
    @State private var isScrubbing = false
    @State private var scrollFraction: CGFloat = 0
    @State private var scrollableHeight: CGFloat = 0
    @State private var visibleMonth: String?
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

    var body: some View {
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
                .padding(.bottom, isSelecting ? 90 : 0)
            }
            .scrollPosition($scrollPosition)
            .scrollIndicators(.hidden)
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { rowIDs in
                visibleMonth = rowIDs.first.flatMap { model.monthByRowID[$0] }
            }
            .simultaneousGesture(
                pinchGesture(
                    viewportWidth: geometry.size.width,
                    viewportHeight: geometry.size.height
                )
            )
            .onScrollGeometryChange(for: TimelineScrollState.self) { scroll in
                let scrollable = max(0, scroll.contentSize.height - scroll.containerSize.height)
                let rawFraction = scrollable > 0 ? scroll.contentOffset.y / scrollable : 0
                let fraction = (min(1, max(0, rawFraction)) * 1_000).rounded() / 1_000
                return TimelineScrollState(
                    fraction: fraction,
                    scrollableHeight: scrollable
                )
            } action: { _, state in
                scrollableHeight = state.scrollableHeight
                guard !isScrubbing else { return }
                scrollFraction = state.fraction
            }
            .onScrollPhaseChange { _, newPhase in
                if newPhase == .idle {
                    scheduleScrubberHide()
                } else {
                    showScrubber()
                }
            }
            .onChange(of: isScrubbing) { _, scrubbing in
                if scrubbing {
                    showScrubber()
                } else {
                    scheduleScrubberHide()
                }
            }
            .overlay(alignment: .trailing) {
                if model.rows.count > 30 {
                    TimelineScrubber(
                        viewportHeight: geometry.size.height,
                        scrollableHeight: scrollableHeight,
                        visibleMonth: visibleMonth,
                        fraction: $scrollFraction,
                        visible: scrubberVisible || isScrubbing,
                        isScrubbing: $isScrubbing
                    ) { offset in
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            scrollPosition.scrollTo(y: offset)
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
        .navigationDestination(item: $viewer) { context in
            AssetViewerScreen(
                assets: context.assets,
                initialIndex: context.index,
                zoomNamespace: zoomNamespace
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
                .onAppear { Task { await model.loadBucket(bucketID) } }
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

                let preservedFraction = scrollFraction
                let generator = UISelectionFeedbackGenerator()
                generator.selectionChanged()

                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    columnCount = target
                    model.columns = target
                }

                let newSide = (viewportWidth - CGFloat(target - 1) * 2) / CGFloat(target)
                let contentHeight = model.rows.reduce(CGFloat(0)) { $0 + $1.height(tileSide: newSide) }
                scrollPosition.scrollTo(y: preservedFraction * max(0, contentHeight - viewportHeight))
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
        let flat = model.flatAssets
        guard let index = flat.firstIndex(where: { $0.id == asset.id }) else { return }
        viewer = ViewerContext(assets: flat, index: index)
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
        scrubberHideTask?.cancel()
        scrubberHideTask = nil
        if reduceMotion {
            scrubberVisible = true
        } else {
            withAnimation(.easeOut(duration: 0.16)) { scrubberVisible = true }
        }
    }

    private func scheduleScrubberHide() {
        scrubberHideTask?.cancel()
        scrubberHideTask = Task {
            try? await Task.sleep(for: .milliseconds(3_200))
            guard !Task.isCancelled, !isScrubbing else { return }
            if reduceMotion {
                scrubberVisible = false
            } else {
                withAnimation(.easeOut(duration: 0.2)) { scrubberVisible = false }
            }
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
    let scrollableHeight: CGFloat
    let visibleMonth: String?
    @Binding var fraction: CGFloat
    let visible: Bool
    @Binding var isScrubbing: Bool
    let onJump: (CGFloat) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var label: String?
    @State private var labelHideTask: Task<Void, Never>?
    @State private var lastMonth: String?

    private let trackTop: CGFloat = 64
    private let trackBottom: CGFloat = 82
    private let thumbHeight: CGFloat = 36

    private var trackHeight: CGFloat {
        max(1, viewportHeight - trackTop - trackBottom - thumbHeight)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
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

                Capsule()
                    .fill(.secondary.opacity(0.72))
                    .frame(width: 4, height: thumbHeight)
                    .frame(width: 36, height: 44)
                    .contentShape(.rect)
            }
            .offset(y: trackTop + fraction * trackHeight)
            .opacity(visible ? 1 : 0)
        }
        .frame(width: 176, height: viewportHeight, alignment: .topTrailing)
        .overlay(alignment: .trailing) {
            Color.black.opacity(0.001)
                .frame(width: 44, height: viewportHeight)
                .contentShape(.rect)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard visible || isScrubbing else { return }
                            labelHideTask?.cancel()
                            if let visibleMonth { setLabel(visibleMonth) }
                            isScrubbing = true
                            fraction = min(1, max(0, (value.location.y - trackTop - thumbHeight / 2) / trackHeight))
                            onJump(fraction * scrollableHeight)
                        }
                        .onEnded { _ in
                            isScrubbing = false
                            scheduleLabelHide()
                        }
                )
                .allowsHitTesting(visible || isScrubbing)
                .accessibilityIdentifier("timeline-scrubber")
        }
        .onChange(of: visibleMonth) { _, month in
            guard isScrubbing || label != nil, let month else { return }
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
