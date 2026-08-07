import SwiftUI

private struct TimelineScrollState: Equatable {
    let fraction: CGFloat
    let scrollableHeight: CGFloat
}

/// plain box written from scroll callbacks and read when a realtime rows
/// update lands. nothing here is observed, so per-frame writes never
/// re-render anything.
@MainActor
private final class ScrollContext {
    var offsetY: CGFloat = 0
    var firstVisibleRowID: String?
    /// the whole visible run, not just the first row: only tile rows anchor a
    /// prefetch window and the top row is usually a month header.
    var visibleRowIDs: [String] = []
    var isIdle = true
    var viewportWidth: CGFloat = 0
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
    /// main photos tab only: weave in device photos and show backup badges.
    var mergesLocalPhotos = false
    /// hosts bump this after mutating the grid's contents server-side, e.g.
    /// adding album photos. the model resyncs in place with an animated
    /// reflow instead of the host remounting the whole screen.
    var resyncTrigger = 0
    /// album grids pass their owner so the viewer can offer removal to the
    /// people the server accepts it from. the id itself comes from the filter.
    var albumOwnerID: String?
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
    @State private var scrollContext = ScrollContext()
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var pendingAlbumAssets: [String]?
    @State private var columnCount = 3
    @State private var pinchBaseColumns: Int?
    @State private var prefetcher = ThumbnailPrefetcher()
    @State private var tileRegistry = AssetTileRegistry()

    init(
        title: String,
        filter: TimelineFilter,
        emptyIcon: String = "photo.on.rectangle",
        emptyMessage: String = "No photos yet",
        showsLargeTitle: Bool = true,
        mergesLocalPhotos: Bool = false,
        resyncTrigger: Int = 0,
        albumOwnerID: String? = nil,
        @ViewBuilder header: () -> Header = { EmptyView() }
    ) {
        self.title = title
        self.filter = filter
        self.emptyIcon = emptyIcon
        self.emptyMessage = emptyMessage
        self.showsLargeTitle = showsLargeTitle
        self.mergesLocalPhotos = mergesLocalPhotos
        self.resyncTrigger = resyncTrigger
        self.albumOwnerID = albumOwnerID
        self.header = header()
        _model = State(initialValue: TimelineModel(filter: filter, mergesLocal: mergesLocalPhotos))
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
                scrollContext.firstVisibleRowID = rowIDs.first
                scrollContext.visibleRowIDs = rowIDs
                prefetcher.update(visibleRowIDs: rowIDs, model: model, client: session.client, backup: session.backup)
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
            // precise offset for scroll compensation; the quantized fraction
            // above is too coarse to re-anchor by. plain box write, no render.
            .onScrollGeometryChange(for: CGFloat.self) { scroll in
                scroll.contentOffset.y
            } action: { _, offset in
                scrollContext.offsetY = offset
            }
            .onChange(of: geometry.size.width, initial: true) { _, width in
                scrollContext.viewportWidth = width
            }
            // the window is otherwise only recomputed while scrolling, so a
            // grid that has just filled in sits with nothing warmed past the
            // fold until the first drag.
            .onChange(of: model.flatAssets.count) {
                prefetcher.update(
                    visibleRowIDs: scrollContext.visibleRowIDs,
                    model: model,
                    client: session.client,
                    backup: session.backup
                )
            }
            .onScrollPhaseChange { _, newPhase in
                scrollContext.isIdle = newPhase == .idle
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
                    onRemoveFromAlbum: filter.albumId != nil ? { await applyRemoveFromAlbum() } : nil,
                    onAddToAlbum: { pendingAlbumAssets = Array(selection) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: isSelecting)
        // no pull-to-refresh: the realtime hub keeps every grid current.
        .task {
            if let client = session.client {
                model.attach(client, backup: session.backup, hub: session.realtime)
                model.columns = columnCount
                // capture list only - a self capture would cycle through the
                // @state storage that owns the model and leak it on pop. the
                // weak capture is renamed so it does not shadow the strong
                // reference this task already holds.
                model.applyRowsUpdate = { [weak weakModel = model, context = scrollContext, position = _scrollPosition] old, new, apply in
                    Self.applyRowsChange(
                        old: old, new: new, apply: apply,
                        model: weakModel, context: context, position: position
                    )
                }
                await model.load()
            }
        }
        .onChange(of: resyncTrigger) {
            model.requestResync()
        }
        // the pipeline outlives the screen, so a window left open would keep
        // downloading tiles for a grid nobody is looking at.
        .onDisappear { prefetcher.cancel() }
        .sheet(item: $pendingAlbumAssets) { ids in
            AlbumPickerSheet(assetIDs: ids) {
                exitSelection()
            }
        }
    }

    // MARK: - rows

    /// lands a realtime rows swap the way the official clients do: content
    /// that changed above the viewport applies instantly with the scroll
    /// offset shifted by the exact height delta, so visible photos never
    /// move; changes in or below the viewport reflow with an animation.
    private static func applyRowsChange(
        old: [TimelineRow],
        new: [TimelineRow],
        apply: () -> Void,
        model: TimelineModel?,
        context: ScrollContext,
        position: State<ScrollPosition>
    ) {
        if context.isIdle,
           let model,
           context.viewportWidth > 0,
           let anchor = context.firstVisibleRowID {
            let side = (context.viewportWidth - CGFloat(model.columns - 1) * 2) / CGFloat(model.columns)
            if let oldStart = TimelineModel.rowStart(of: anchor, in: old, tileSide: side),
               let newStart = TimelineModel.rowStart(of: anchor, in: new, tileSide: side),
               abs(newStart - oldStart) > 0.5 {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    apply()
                    position.wrappedValue.scrollTo(y: max(0, context.offsetY + newStart - oldStart))
                }
                return
            }
        }
        if UIAccessibility.isReduceMotionEnabled || !context.isIdle {
            apply()
        } else {
            withAnimation(.smooth(duration: 0.3)) { apply() }
        }
    }

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
                if isSelecting, !assetIDs.isEmpty {
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
                        // plain crossfade: an uploaded photo swaps its local
                        // tile for the server twin with identical pixels, and
                        // any scale effect would read as a pulse.
                        .transition(.opacity)
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
        // selection mode keeps taps as the only gesture, like the system
        // photos app.
        if isSelecting {
            AssetTile(asset: asset, showsBackupBadge: mergesLocalPhotos)
                .overlay(alignment: .topLeading) {
                    if !asset.isLocal {
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
                    if selection.contains(asset.id) {
                        Rectangle().stroke(Color.accentColor, lineWidth: 3)
                    }
                }
                .onTapGesture {
                    // server actions cannot target device-only photos.
                    if !asset.isLocal { toggle(asset) }
                }
        } else {
            InteractiveAssetTile(
                asset: asset,
                showsBackupBadge: mergesLocalPhotos,
                registry: tileRegistry,
                menu: { UIMenu(children: menuElements(for: asset)) },
                makeViewer: { startsAsContextPreview, bounds in
                    viewerController(
                        for: asset,
                        startsAsContextPreview: startsAsContextPreview,
                        previewBounds: bounds
                    )
                }
            )
        }
    }

    // MARK: - context menu

    /// single-asset menu behind the long-press preview. mirrors the action
    /// set of the selection bar for the current screen.
    private func menuElements(for asset: Asset) -> [UIMenuElement] {
        if asset.isLocal { return localMenuElements(for: asset) }
        var main: [UIMenuElement] = []
        if filter.isTrashed == true {
            main.append(UIAction(title: "Restore", image: UIImage(systemName: "arrow.uturn.backward")) { _ in
                Task { await restore(ids: [asset.id]) }
            })
        } else {
            main.append(UIAction(
                title: asset.isFavorite ? "Unfavorite" : "Favorite",
                image: UIImage(systemName: asset.isFavorite ? "heart.slash" : "heart")
            ) { _ in
                Task { await favorite(ids: [asset.id], value: !asset.isFavorite) }
            })
            main.append(UIAction(title: "Add to Album", image: UIImage(systemName: "rectangle.stack.badge.plus")) { _ in
                pendingAlbumAssets = [asset.id]
            })
            if filter.albumId != nil {
                main.append(UIAction(title: "Remove from Album", image: UIImage(systemName: "rectangle.stack.badge.minus")) { _ in
                    Task { await removeFromAlbum(ids: [asset.id]) }
                })
            } else {
                main.append(UIAction(
                    title: filter.visibility == .archive ? "Unarchive" : "Archive",
                    image: UIImage(systemName: filter.visibility == .archive ? "tray.and.arrow.up" : "archivebox")
                ) { _ in
                    Task { await setVisibility(ids: [asset.id], filter.visibility == .archive ? .timeline : .archive) }
                })
            }
        }
        main.append(UIAction(title: "Select", image: UIImage(systemName: "checkmark.circle")) { _ in
            isSelecting = true
            selection.insert(asset.id)
        })
        let trash = UIAction(
            title: filter.isTrashed == true ? "Delete" : "Move to Trash",
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { _ in
            Task { await self.trash(ids: [asset.id]) }
        }
        return [
            UIMenu(options: .displayInline, children: main),
            UIMenu(options: .displayInline, children: [trash]),
        ]
    }

    /// device-only photos have no server actions. deletion goes through the
    /// system photo library dialog, so no extra confirmation is needed, and
    /// the library observer removes the tile once the change lands.
    private func localMenuElements(for asset: Asset) -> [UIMenuElement] {
        guard let localId = asset.localIdentifier else { return [] }
        let delete = UIAction(
            title: "Delete from Device",
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { _ in
            Task {
                // declining the system dialog throws and must not be
                // recorded as a deletion.
                do {
                    try await PhotoLibraryService.delete(localIdentifiers: [localId])
                } catch {
                    return
                }
                session.backup?.noteLocalDeletion([localId])
            }
        }
        return [UIMenu(options: .displayInline, children: [delete])]
    }

    @ViewBuilder private var overlayState: some View {
        // rows, not sections: cache-restored months and merged device photos
        // are real content, and a failed server load must not cover them.
        if model.isLoading && model.rows.isEmpty {
            ProgressView()
        } else if let error = model.loadError, model.rows.isEmpty {
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

    private func viewerController(
        for asset: Asset,
        startsAsContextPreview: Bool,
        previewBounds: CGSize
    ) -> AssetViewerHostingController? {
        guard let index = model.flatAssetIndex(for: asset.id) else { return nil }
        guard let route = viewer.makeRoute(assets: model.flatAssets, initialIndex: index) else { return nil }

        return AssetViewerHostingController(
            route: route,
            startsAsContextPreview: startsAsContextPreview,
            previewBounds: previewBounds,
            session: session,
            sourceRegistry: tileRegistry,
            album: filter.albumId.map { AlbumContext(id: $0, ownerID: albumOwnerID) },
            willPresent: { route in beginViewerPresentation(route) },
            didDismiss: { id in finishViewer(id) },
            onChange: { change in handleViewerChange(change) }
        )
    }

    private func beginViewerPresentation(_ route: ViewerRoute) -> Bool {
        // Only one UIKit viewer can own Timeline suspension. Its completion
        // clears this gate at the same point the native zoom gives back control.
        guard viewer.activate(route, presentsCover: false) else { return false }
        model.suspendForViewer()
        hideScrubberForViewer()
        return true
    }

    private func finishViewer(_ id: UUID) {
        viewer.complete(id)
        Task {
            // a short cushion past the zoom out, no more: the rebuild it used
            // to guard against is debounced now, and the wait was long enough
            // to be felt when reopening straight away.
            try? await Task.sleep(for: .milliseconds(120))
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
        case .edited(let id, let thumbhash):
            model.updateAssets(ids: [id]) { asset in
                if let thumbhash { asset.thumbhash = thumbhash }
            }
        }
    }

    // MARK: - asset actions

    private func favorite(ids: [String], value: Bool) async {
        guard let client = session.client else { return }
        try? await client.setFavorite(ids: ids, value)
        model.updateAssets(ids: Set(ids)) { $0.isFavorite = value }
    }

    private func setVisibility(ids: [String], _ value: AssetVisibility) async {
        guard let client = session.client else { return }
        try? await client.setVisibility(ids: ids, value)
        model.removeAssets(ids: Set(ids))
    }

    /// false when the user declines deleting the paired device copies.
    @discardableResult
    private func trash(ids: [String]) async -> Bool {
        guard let client = session.client else { return false }
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
                    return false
                }
                backup.noteLocalDeletion(localIds)
            }
        }
        try? await client.trashAssets(ids: ids)
        model.removeAssets(ids: Set(ids))
        return true
    }

    private func restore(ids: [String]) async {
        guard let client = session.client else { return }
        try? await client.restoreAssets(ids: ids)
        model.removeAssets(ids: Set(ids))
    }

    private func removeFromAlbum(ids: [String]) async {
        guard let client = session.client, let albumID = filter.albumId else { return }
        _ = try? await client.removeAssets(albumID: albumID, ids: ids)
        model.removeAssets(ids: Set(ids))
    }

    // MARK: - bulk actions

    private func applyFavorite() async {
        await favorite(ids: Array(selection), value: true)
        exitSelection()
    }

    private func applyVisibility(_ value: AssetVisibility) async {
        await setVisibility(ids: Array(selection), value)
        exitSelection()
    }

    private func applyTrash() async {
        guard await trash(ids: Array(selection)) else { return }
        exitSelection()
    }

    private func applyRestore() async {
        await restore(ids: Array(selection))
        exitSelection()
    }

    private func applyRemoveFromAlbum() async {
        await removeFromAlbum(ids: Array(selection))
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

/// uikit-hosted tile owning tap and long press. swiftui's contextMenu cannot
/// commit when the floating preview is tapped, so the interaction is bridged
/// on the same view that draws the tile. UIKit owns its temporary preview and
/// source visibility; the app keeps no duplicate or delayed cleanup view.
private struct InteractiveAssetTile: UIViewRepresentable {
    @Environment(SessionStore.self) private var session
    let asset: Asset
    let showsBackupBadge: Bool
    let registry: AssetTileRegistry
    let menu: () -> UIMenu
    let makeViewer: (_ startsAsContextPreview: Bool, _ bounds: CGSize) -> AssetViewerHostingController?

    func makeUIView(context: Context) -> UIView {
        let view = configuration.makeContentView()
        view.backgroundColor = .clear
        view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        view.addGestureRecognizer(UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.tapped(_:))
        ))
        context.coordinator.register(view, assetID: asset.id, in: registry)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.host = self
        context.coordinator.register(uiView, assetID: asset.id, in: registry)
        (uiView as? UIContentView)?.configuration = configuration
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.unregister(uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(host: self, registry: registry)
    }

    /// the hosted root does not inherit this screen's environment, so the
    /// session is re-injected.
    private var configuration: UIHostingConfiguration<some View, some View> {
        UIHostingConfiguration {
            AssetTile(asset: asset, showsBackupBadge: showsBackupBadge)
                .environment(session)
        }
        .margins(.all, 0)
    }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var host: InteractiveAssetTile
        private var registry: AssetTileRegistry
        private var registeredAssetID: String?

        init(host: InteractiveAssetTile, registry: AssetTileRegistry) {
            self.host = host
            self.registry = registry
        }

        func register(_ view: UIView, assetID: String, in registry: AssetTileRegistry) {
            if (self.registry !== registry || registeredAssetID != assetID),
               let registeredAssetID {
                self.registry.unregister(view, for: registeredAssetID)
            }
            self.registry = registry
            registeredAssetID = assetID
            registry.register(view, for: assetID)
        }

        func unregister(_ view: UIView) {
            guard let registeredAssetID else { return }
            registry.unregister(view, for: registeredAssetID)
            self.registeredAssetID = nil
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view,
                  let bounds = view.window?.bounds.size,
                  let presenter = presentationAnchor(for: view),
                  let viewer = host.makeViewer(false, bounds)
            else { return }
            viewer.presentDirectly(from: presenter)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard let bounds = interaction.view?.window?.bounds.size else { return nil }
            let viewer = host.makeViewer(true, bounds)
            return UIContextMenuConfiguration(
                identifier: host.asset.id as NSString,
                previewProvider: { viewer },
                actionProvider: { _ in self.host.menu() }
            )
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
            animator: UIContextMenuInteractionCommitAnimating
        ) {
            guard let view = interaction.view,
                  let presenter = presentationAnchor(for: view),
                  let viewer = animator.previewViewController as? AssetViewerHostingController,
                  viewer.prepareForContextCommit()
            else { return }

            // `.pop` expands the preview that is already on screen. Once that
            // animation releases it, install that exact controller with no
            // second animation or delayed full-screen-cover presentation.
            animator.preferredCommitStyle = .pop
            animator.addAnimations {
                viewer.revealViewerForContextCommit()
            }
            animator.addCompletion {
                viewer.attachAfterContextCommit(to: presenter)
            }
        }

        /// Presents from the stable container above SwiftUI's hosting child.
        /// The context-menu presentation itself is transient and has completed
        /// by the time the captured controller is asked to attach the viewer.
        private func presentationAnchor(for view: UIView) -> UIViewController? {
            var responder: UIResponder? = view
            var controller: UIViewController?
            while let current = responder {
                if let current = current as? UIViewController {
                    controller = current
                    break
                }
                responder = current.next
            }
            guard var controller else { return nil }
            while let parent = controller.parent {
                controller = parent
            }
            return controller
        }
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
    var onRemoveFromAlbum: (() async -> Void)?
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
                } else if let onRemoveFromAlbum {
                    barButton("heart", "Favorite") { Task { await onFavorite() } }
                    barButton("rectangle.stack.badge.plus", "Album", action: onAddToAlbum)
                    barButton("rectangle.stack.badge.minus", "Remove") { Task { await onRemoveFromAlbum() } }
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
