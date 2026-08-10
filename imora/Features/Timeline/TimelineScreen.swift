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

nonisolated enum TimelineServerCommand: Equatable {
    case restoreAllTrash
    case emptyTrash
}

/// reusable bucketed photo grid, the workhorse behind most screens.
struct TimelineScreen<Header: View>: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

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
    /// Keeps AlbumDetail's metadata header in lockstep with direct grid
    /// removals without coupling this reusable screen to album state.
    var onAlbumAssetCountDelta: ((Int) -> Void)?
    @Binding private var serverCommand: TimelineServerCommand?
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
    @State private var pendingEditAsset: Asset?
    @State private var preparedShare: PreparedAssetShare?
    @State private var sharingAssetIDs = Set<String>()
    @State private var downloadingAssetIDs = Set<String>()
    /// Serializes mutations per asset while still allowing unrelated photos
    /// to update concurrently. The set also disables bulk actions that overlap
    /// an in-flight context-menu command.
    @State private var mutatingAssetIDs = Set<String>()
    /// Downloads update the persisted pairing asynchronously. Keeping the new
    /// identifier here makes a reopened context menu correct immediately.
    @State private var downloadedLocalIdentifiers: [String: String] = [:]
    @State private var columnCount = 3
    @State private var pinchBaseColumns: Int?
    @State private var prefetcher = ThumbnailPrefetcher()
    @State private var tileRegistry = AssetTileRegistry()
    @State private var isRunningServerCommand = false

    init(
        title: String,
        filter: TimelineFilter,
        emptyIcon: String = "photo.on.rectangle",
        emptyMessage: String = "No photos yet",
        showsLargeTitle: Bool = true,
        mergesLocalPhotos: Bool = false,
        resyncTrigger: Int = 0,
        albumOwnerID: String? = nil,
        onAlbumAssetCountDelta: ((Int) -> Void)? = nil,
        serverCommand: Binding<TimelineServerCommand?> = .constant(nil),
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
        self.onAlbumAssetCountDelta = onAlbumAssetCountDelta
        _serverCommand = serverCommand
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
                        .disabled(isRunningServerCommand || !selection.isDisjoint(with: mutatingAssetIDs))
                }
            }
        }
        .overlay { overlayState }
        .overlay(alignment: .bottom) {
            if isSelecting {
                SelectionActionBar(
                    count: selection.count,
                    filter: filter,
                    isWorking: isRunningServerCommand || !selection.isDisjoint(with: mutatingAssetIDs),
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
        .onChange(of: serverCommand) { _, command in
            guard let command else { return }
            serverCommand = nil
            Task { await run(command) }
        }
        // the pipeline outlives the screen, so a window left open would keep
        // downloading tiles for a grid nobody is looking at.
        .onDisappear { prefetcher.cancel() }
        .sheet(item: $pendingAlbumAssets) { ids in
            AlbumPickerSheet(
                assetIDs: ids,
                onApplied: exitSelection,
                onRollback: { failedIDs in
                    selection.formUnion(failedIDs)
                    isSelecting = !selection.isEmpty
                }
            )
        }
        .sheet(item: $preparedShare) { share in
            TimelineShareSheet(url: share.url)
        }
        .fullScreenCover(item: $pendingEditAsset) { asset in
            AssetEditScreen(asset: asset) { outcome in
                guard case .saved(let detail) = outcome else { return }
                model.updateAssets(ids: [asset.id]) { current in
                    if let thumbhash = detail?.thumbhash { current.thumbhash = thumbhash }
                }
                // The device original is no longer a valid render source for
                // the edited server asset, even when refreshing its detail fails.
                session.backup?.noteRemoteEdits([asset.id])
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
        case .titleBand(_, let segments):
            // leading padding instead of offset keeps each segment in layout,
            // so positions stay exact and hit testing needs no transforms.
            ZStack(alignment: .bottomLeading) {
                ForEach(segments, id: \.dayID) { segment in
                    titleSegment(segment, side: side)
                        .padding(.leading, CGFloat(segment.colStart) * (side + 2))
                }
            }
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
            .frame(height: 36, alignment: .bottomLeading)

        case .tiles(_, let runs):
            ZStack(alignment: .topLeading) {
                ForEach(runs, id: \.colStart) { run in
                    HStack(spacing: 2) {
                        ForEach(run.assets) { asset in
                            tile(asset)
                                .frame(width: side, height: side)
                                // plain crossfade: an uploaded photo swaps its
                                // local tile for the server twin with identical
                                // pixels, and any scale effect would read as a
                                // pulse.
                                .transition(.opacity)
                        }
                    }
                    .padding(.leading, CGFloat(run.colStart) * (side + 2))
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.bottom, 2)

        case .placeholder(_, let bucketID, let tileRows):
            PlaceholderGrid(tileRows: tileRows, columns: columnCount, side: side)
                // debounced rows: a synchronous rebuild here changes the
                // bottom padding inside the scroll pass that revealed the
                // placeholder, re entering the geometry callbacks same frame.
                .onAppear { Task { await model.loadBucket(bucketID, immediateRows: false) } }
        }
    }

    private func titleSegment(_ segment: TitleSegment, side: CGFloat) -> some View {
        let width = CGFloat(segment.colWidth) * side + CGFloat(segment.colWidth - 1) * 2
        let selectableIDs = segment.selectableIDs.filter(isSelectableAssetID)
        return HStack(spacing: 4) {
            Text(segment.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
            if isSelecting, !selectableIDs.isEmpty {
                let allSelected = selectableIDs.allSatisfy { selection.contains($0) }
                Button {
                    if allSelected {
                        selection.subtract(selectableIDs)
                    } else {
                        selection.formUnion(selectableIDs)
                    }
                } label: {
                    Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(allSelected ? Color.accentColor : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .animation(.snappy(duration: 0.22), value: allSelected)
                }
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.bottom, 5)
        .frame(width: width, height: 36, alignment: .bottomLeading)
    }

    @ViewBuilder private func tile(_ asset: Asset) -> some View {
        // selection mode keeps taps as the only gesture, like the system
        // photos app.
        if isSelecting {
            AssetTile(asset: asset, showsBackupBadge: mergesLocalPhotos)
                .overlay(alignment: .topLeading) {
                    if isSelectable(asset) {
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
                    if isSelectable(asset) { toggle(asset) }
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

    /// Single-asset menu behind the long-press preview. Eligibility comes from
    /// the same device/server/owner policy as the viewer, so partner assets and
    /// paired device copies cannot accidentally receive owner-only actions.
    private func menuElements(for asset: Asset) -> [UIMenuElement] {
        let serverID = serverIdentifier(for: asset)
        let pairedLocalID = pairedLocalIdentifier(for: asset)
        let availability = AssetActionAvailability(
            asset: asset,
            ownsAsset: owns(asset),
            localRemoteIdentifier: asset.isLocal ? serverID : nil,
            pairedLocalIdentifier: pairedLocalID
        )
        let mutationAttributes: UIMenuElement.Attributes = isRunningServerCommand || mutatingAssetIDs.contains(asset.id)
            ? .disabled
            : []

        var primary: [UIMenuElement] = []
        if availability.canRestore, let serverID {
            primary.append(UIAction(
                title: "Restore",
                image: UIImage(systemName: "arrow.uturn.backward"),
                attributes: mutationAttributes
            ) { _ in
                Task { _ = await restore(ids: [serverID]) }
            })
        }
        if availability.canFavorite, let serverID {
            primary.append(UIAction(
                title: asset.isFavorite ? "Unfavorite" : "Favorite",
                image: UIImage(systemName: asset.isFavorite ? "heart.slash" : "heart"),
                attributes: mutationAttributes
            ) { _ in
                Task { _ = await favorite(ids: [serverID], value: !asset.isFavorite) }
            })
        }
        if availability.canEdit {
            primary.append(UIAction(title: "Edit", image: UIImage(systemName: "slider.horizontal.3")) { _ in
                pendingEditAsset = asset
            })
        }
        if availability.canAddToAlbum, let serverID {
            primary.append(UIAction(title: "Add to Album", image: UIImage(systemName: "rectangle.stack.badge.plus")) { _ in
                pendingAlbumAssets = [serverID]
            })
        }
        if canRemoveFromAlbum(asset), let serverID {
            primary.append(UIAction(
                title: "Remove from Album",
                image: UIImage(systemName: "rectangle.stack.badge.minus"),
                attributes: mutationAttributes
            ) { _ in
                Task { _ = await removeFromAlbum(ids: [serverID]) }
            })
        }
        if availability.canArchive, let serverID {
            let isArchived = asset.visibility == .archive
            primary.append(UIAction(
                title: isArchived ? "Unarchive" : "Archive",
                image: UIImage(systemName: isArchived ? "tray.and.arrow.up" : "archivebox"),
                attributes: mutationAttributes
            ) { _ in
                Task { _ = await setVisibility(ids: [serverID], isArchived ? .timeline : .archive) }
            })
        }
        if isSelectable(asset) {
            primary.append(UIAction(title: "Select", image: UIImage(systemName: "checkmark.circle")) { _ in
                isSelecting = true
                selection.insert(asset.id)
            })
        }

        var transfer: [UIMenuElement] = []
        if sharingAssetIDs.contains(asset.id) {
            transfer.append(UIAction(
                title: "Preparing Share…",
                image: UIImage(systemName: "square.and.arrow.up"),
                attributes: .disabled
            ) { _ in })
        } else {
            transfer.append(UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                Task { await share(asset) }
            })
        }
        if asset.isLocal, let localID = asset.localIdentifier {
            transfer.append(backupMenuElement(for: asset, localID: localID, availability: availability))
        }
        if availability.canDownload {
            if downloadingAssetIDs.contains(asset.id) {
                transfer.append(UIAction(
                    title: "Downloading…",
                    image: UIImage(systemName: "arrow.down.circle.dotted"),
                    attributes: .disabled
                ) { _ in })
            } else {
                transfer.append(UIAction(title: "Download to Device", image: UIImage(systemName: "arrow.down.circle")) { _ in
                    Task { await download(asset) }
                })
            }
        }
        if let serverID, !asset.isTrashed {
            transfer.append(UIAction(title: "Open in Browser", image: UIImage(systemName: "safari")) { _ in
                Task { await openInBrowser(serverID: serverID) }
            })
        }

        var destructive: [UIMenuElement] = []
        if availability.canDeleteFromDevice, let pairedLocalID {
            destructive.append(UIAction(
                title: "Delete from This Device",
                image: UIImage(systemName: "iphone.slash"),
                attributes: .destructive
            ) { _ in
                Task { await deleteFromDevice(asset: asset, localID: pairedLocalID) }
            })
        }
        if availability.canTrashEverywhere, serverID != nil {
            destructive.append(UIAction(
                title: pairedLocalID == nil ? "Move to Trash" : "Move to Trash Everywhere",
                image: UIImage(systemName: "trash"),
                attributes: [.destructive, mutationAttributes]
            ) { _ in
                Task { _ = await deleteAssets([asset], force: false) }
            })
        }
        if availability.canDeletePermanently, serverID != nil {
            destructive.append(UIAction(
                title: "Delete Permanently",
                image: UIImage(systemName: "trash.slash"),
                attributes: [.destructive, mutationAttributes]
            ) { _ in
                Task { _ = await deleteAssets([asset], force: true) }
            })
        }

        var sections: [UIMenuElement] = []
        if !primary.isEmpty { sections.append(UIMenu(options: .displayInline, children: primary)) }
        if !transfer.isEmpty { sections.append(UIMenu(options: .displayInline, children: transfer)) }
        if !destructive.isEmpty { sections.append(UIMenu(options: .displayInline, children: destructive)) }
        return sections
    }

    private func backupMenuElement(
        for asset: Asset,
        localID: String,
        availability: AssetActionAvailability
    ) -> UIMenuElement {
        switch session.backup?.uploadStates[localID] {
        case .uploading(let fraction):
            let percent = Int((fraction * 100).rounded())
            return UIAction(
                title: "Backing Up… \(percent)%",
                image: UIImage(systemName: "icloud.and.arrow.up"),
                attributes: .disabled
            ) { _ in }
        case .failed:
            return UIAction(title: "Retry Backup", image: UIImage(systemName: "exclamationmark.icloud")) { _ in
                Task { await backUp(localID: localID) }
            }
        case nil:
            if !availability.canBackUp {
                return UIAction(
                    title: "Backed Up",
                    image: UIImage(systemName: "checkmark.icloud"),
                    attributes: .disabled
                ) { _ in }
            }
            guard session.backup != nil else {
                return UIAction(
                    title: "Backup Unavailable",
                    image: UIImage(systemName: "icloud.slash"),
                    attributes: .disabled
                ) { _ in }
            }
            return UIAction(title: "Back Up Now", image: UIImage(systemName: "icloud.and.arrow.up")) { _ in
                Task { await backUp(localID: localID) }
            }
        }
    }

    private func serverIdentifier(for asset: Asset) -> String? {
        guard asset.isLocal else { return asset.id }
        guard let localID = asset.localIdentifier else { return nil }
        return session.backup?.remoteIdentifierByLocalId[localID]
    }

    private func pairedLocalIdentifier(for asset: Asset) -> String? {
        if let localID = asset.localIdentifier { return localID }
        return downloadedLocalIdentifiers[asset.id]
            ?? session.backup?.pairedLocalIdentifierByRemoteId[asset.id]
    }

    private func owns(_ asset: Asset) -> Bool {
        if asset.isLocal { return true }
        guard let userID = session.user?.id else { return true }
        return asset.ownerId == userID
    }

    private func canRemoveFromAlbum(_ asset: Asset) -> Bool {
        guard filter.albumId != nil, !asset.isLocal else { return false }
        guard let userID = session.user?.id else { return true }
        return asset.ownerId == userID || albumOwnerID == userID
    }

    private func isSelectable(_ asset: Asset) -> Bool {
        !asset.isLocal && owns(asset)
    }

    private func isSelectableAssetID(_ id: String) -> Bool {
        guard let index = model.flatAssetIndex(for: id) else { return false }
        return isSelectable(model.flatAssets[index])
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
            if let requiredValue = filter.isFavorite {
                if value == requiredValue {
                    model.rollbackExternalOptimisticRemoval(id: id)
                    model.updateAssets(ids: [id]) { $0.isFavorite = value }
                } else {
                    model.beginExternalOptimisticRemoval(id: id)
                }
            } else {
                model.beginExternalOptimisticFavorite(id: id, value: value)
            }
        case .favoriteCommitted(let id, let value):
            if let requiredValue = filter.isFavorite, value != requiredValue {
                model.commitExternalOptimisticRemoval(id: id)
            } else if filter.isFavorite == nil {
                model.commitExternalOptimisticFavorite(id: id)
            }
        case .optimisticRemoval(let id):
            model.beginExternalOptimisticRemoval(id: id)
        case .removalCommitted(let id):
            model.commitExternalOptimisticRemoval(id: id)
        case .removalReverted(let id):
            model.rollbackExternalOptimisticRemoval(id: id)
        case .albumMembershipProjected:
            onAlbumAssetCountDelta?(-1)
        case .albumMembershipCommitted:
            break
        case .albumMembershipReverted:
            onAlbumAssetCountDelta?(1)
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

    private func run(_ command: TimelineServerCommand) async {
        guard !isRunningServerCommand else {
            ErrorToastCenter.shared.show("A trash action is already in progress.")
            return
        }
        let action = command == .restoreAllTrash
            ? "Couldn’t restore the trash"
            : "Couldn’t empty the trash"
        guard mutatingAssetIDs.isEmpty else {
            ErrorToastCenter.shared.show("Wait for the current photo action to finish.")
            return
        }
        guard let client = session.client else {
            ErrorToastCenter.shared.show("\(action). The server is not available.")
            return
        }
        isRunningServerCommand = true
        let snapshot = model.clearForOptimisticAction()
        exitSelection()
        defer { isRunningServerCommand = false }
        do {
            switch command {
            case .restoreAllTrash:
                try await client.restoreTrash()
            case .emptyTrash:
                try await client.emptyTrash()
            }
            model.commit(snapshot)
        } catch {
            model.restore(snapshot)
            ErrorToastCenter.shared.show(action, error: error)
        }
    }

    // MARK: - asset actions

    @discardableResult
    private func favorite(ids: [String], value: Bool) async -> Bool {
        let requestedIDs = Set(ids)
        guard beginServerMutation(ids: requestedIDs) else { return false }
        defer { finishServerMutation(ids: requestedIDs) }
        guard let client = session.client else {
            ErrorToastCenter.shared.show("Couldn’t update favorites. The server is not available.")
            return false
        }

        let leavesCurrentFilter = filter.isFavorite.map { $0 != value } ?? false
        var favorite: TimelineFavoriteMutation?
        var removal: TimelineRemoval?
        let result: Void? = await OptimisticAction.perform(
            errorMessage: "Couldn’t update favorites",
            apply: {
                if leavesCurrentFilter {
                    removal = model.removeAssetsForOptimisticAction(ids: requestedIDs)
                } else {
                    favorite = model.setFavoriteForOptimisticAction(ids: requestedIDs, value: value)
                }
            },
            rollback: {
                if let removal {
                    model.restore(removal)
                } else if let favorite {
                    model.restore(favorite)
                }
            },
            request: { try await client.setFavorite(ids: ids, value) },
            commit: { _ in
                if let removal {
                    model.commit(removal)
                } else if let favorite {
                    model.commit(favorite)
                }
            }
        )
        return result != nil
    }

    @discardableResult
    private func setVisibility(ids: [String], _ value: AssetVisibility) async -> Bool {
        let requestedIDs = Set(ids)
        guard beginServerMutation(ids: requestedIDs) else { return false }
        defer { finishServerMutation(ids: requestedIDs) }
        guard let client = session.client else {
            ErrorToastCenter.shared.show("The server is not available.")
            return false
        }
        var removal: TimelineRemoval?
        let result: Void? = await OptimisticAction.perform(
            errorMessage: value == .archive ? "Couldn’t archive" : "Couldn’t unarchive",
            apply: { removal = model.removeAssetsForOptimisticAction(ids: requestedIDs) },
            rollback: { if let removal { model.restore(removal) } },
            request: { try await client.setVisibility(ids: ids, value) },
            commit: { _ in if let removal { model.commit(removal) } }
        )
        return result != nil
    }

    private func share(_ asset: Asset) async {
        guard sharingAssetIDs.insert(asset.id).inserted else { return }
        defer { sharingAssetIDs.remove(asset.id) }
        do {
            let url: URL
            if let localID = asset.localIdentifier {
                url = try await LocalSharedAssetFile(localIdentifier: localID).exportedURL()
            } else if let client = session.client {
                url = try await SharedAssetFile(client: client, asset: asset).exportedURL()
            } else {
                ErrorToastCenter.shared.show("Sharing is not available while signed out.")
                return
            }
            preparedShare = PreparedAssetShare(url: url)
        } catch {
            ErrorToastCenter.shared.show("Couldn’t prepare this item for sharing", error: error)
        }
    }

    private func backUp(localID: String) async {
        guard let backup = session.backup else {
            ErrorToastCenter.shared.show("Backup is not available.")
            return
        }
        do {
            _ = try await backup.backUp(localIdentifier: localID)
            await model.refreshLocalItems()
        } catch {
            ErrorToastCenter.shared.show("Couldn’t back up", error: error)
        }
    }

    private func download(_ asset: Asset) async {
        guard let backup = session.backup else {
            ErrorToastCenter.shared.show("Download is not available.")
            return
        }
        guard downloadingAssetIDs.insert(asset.id).inserted else { return }
        defer { downloadingAssetIDs.remove(asset.id) }
        do {
            downloadedLocalIdentifiers[asset.id] = try await backup.download(asset: asset)
        } catch {
            ErrorToastCenter.shared.show("Couldn’t download", error: error)
        }
    }

    private func openInBrowser(serverID: String) async {
        guard let client = session.client else {
            ErrorToastCenter.shared.show("The server is not available.")
            return
        }
        let base = await client.serverWebURL()
        openURL(base.appending(path: "photos/\(serverID)"))
    }

    private func deleteFromDevice(asset: Asset, localID: String) async {
        do {
            try await PhotoLibraryService.delete(localIdentifiers: [localID])
        } catch {
            if !PhotoLibraryService.isUserCancelled(error) {
                ErrorToastCenter.shared.show("Couldn’t delete from this device", error: error)
            }
            return
        }
        downloadedLocalIdentifiers[asset.id] = nil
        session.backup?.noteLocalDeletion([localID])
    }

    /// Device deletion happens first so cancelling the system prompt leaves the
    /// server untouched. Once that irreversible step succeeds, the remote
    /// projection disappears immediately and is restored if the server rejects
    /// its half of the operation.
    @discardableResult
    private func deleteAssets(_ assets: [Asset], force: Bool) async -> Bool {
        guard let client = session.client else {
            ErrorToastCenter.shared.show("The server is not available.")
            return false
        }
        let targets = assets.compactMap { asset -> (sourceID: String, serverID: String)? in
            serverIdentifier(for: asset).map { (asset.id, $0) }
        }
        guard targets.count == assets.count, !targets.isEmpty else {
            ErrorToastCenter.shared.show("This item does not have a server copy yet.")
            return false
        }
        let sourceIDs = Set(targets.map(\.sourceID))
        guard beginServerMutation(ids: sourceIDs) else { return false }
        defer { finishServerMutation(ids: sourceIDs) }

        var localIDs = Set<String>()
        for (asset, target) in zip(assets, targets) {
            if let localID = pairedLocalIdentifier(for: asset) {
                localIDs.insert(localID)
            } else if let backup = session.backup,
                      let localID = await backup.localIdentifier(forRemote: target.serverID) {
                localIDs.insert(localID)
            }
        }
        if !localIDs.isEmpty {
            do {
                try await PhotoLibraryService.delete(localIdentifiers: Array(localIDs))
            } catch {
                if !PhotoLibraryService.isUserCancelled(error) {
                    ErrorToastCenter.shared.show("Couldn’t delete from this device", error: error)
                }
                return false
            }
            session.backup?.noteLocalDeletion(Array(localIDs))
            for target in targets { downloadedLocalIdentifiers[target.serverID] = nil }
        }

        let errorMessage: String
        if localIDs.isEmpty {
            errorMessage = force ? "Couldn’t delete permanently" : "Couldn’t move to trash"
        } else if force {
            errorMessage = "Deleted from this device, but couldn’t permanently delete the server copy"
        } else {
            errorMessage = "Deleted from this device, but couldn’t move the server copy to trash"
        }
        var removal: TimelineRemoval?
        let result: Void? = await OptimisticAction.perform(
            errorMessage: errorMessage,
            apply: { removal = model.removeAssetsForOptimisticAction(ids: sourceIDs) },
            rollback: { if let removal { model.restore(removal) } },
            request: {
                try await client.trashAssets(ids: targets.map(\.serverID), force: force)
            },
            commit: { _ in if let removal { model.commit(removal) } }
        )
        return result != nil
    }

    @discardableResult
    private func restore(ids: [String]) async -> Bool {
        let requestedIDs = Set(ids)
        guard beginServerMutation(ids: requestedIDs) else { return false }
        defer { finishServerMutation(ids: requestedIDs) }
        guard let client = session.client else {
            ErrorToastCenter.shared.show("The server is not available.")
            return false
        }
        var removal: TimelineRemoval?
        let result: Void? = await OptimisticAction.perform(
            errorMessage: "Couldn’t restore",
            apply: { removal = model.removeAssetsForOptimisticAction(ids: requestedIDs) },
            rollback: { if let removal { model.restore(removal) } },
            request: { try await client.restoreAssets(ids: ids) },
            commit: { _ in if let removal { model.commit(removal) } }
        )
        return result != nil
    }

    /// Returns only the ids the server actually removed. Immich can accept a
    /// bulk request while rejecting individual assets for permission reasons.
    private func removeFromAlbum(ids: [String]) async -> Set<String> {
        let requestedIDs = Set(ids)
        guard beginServerMutation(ids: requestedIDs) else { return [] }
        defer { finishServerMutation(ids: requestedIDs) }
        guard let client = session.client, let albumID = filter.albumId else {
            ErrorToastCenter.shared.show("The album is not available.")
            return []
        }
        var removal: TimelineRemoval?
        let results: [BulkIdResult]? = await OptimisticAction.perform(
            errorMessage: "Couldn’t remove from the album",
            apply: {
                removal = model.removeAssetsForOptimisticAction(ids: requestedIDs)
                onAlbumAssetCountDelta?(-requestedIDs.count)
            },
            rollback: {
                if let removal { model.restore(removal) }
                onAlbumAssetCountDelta?(requestedIDs.count)
            },
            request: { try await client.removeAssets(albumID: albumID, ids: ids) }
        )
        guard let results else { return [] }

        let succeeded = Set(results.lazy.filter(\.success).map(\.id))
            .intersection(requestedIDs)
        let failed = requestedIDs.subtracting(succeeded)
        if let removal { model.commit(removal, ids: succeeded) }
        if !failed.isEmpty {
            if let removal { model.restore(removal, ids: failed) }
            onAlbumAssetCountDelta?(failed.count)
            ErrorToastCenter.shared.show(albumRemovalFailureMessage(results, failedCount: failed.count))
        }
        return succeeded
    }

    private func beginServerMutation(ids: Set<String>) -> Bool {
        guard !isRunningServerCommand,
              !ids.isEmpty,
              mutatingAssetIDs.isDisjoint(with: ids)
        else { return false }
        mutatingAssetIDs.formUnion(ids)
        return true
    }

    private func finishServerMutation(ids: Set<String>) {
        mutatingAssetIDs.subtract(ids)
    }

    private func albumRemovalFailureMessage(_ results: [BulkIdResult], failedCount: Int) -> String {
        let base = failedCount == 1
            ? "Couldn’t remove this item from the album."
            : "Couldn’t remove \(failedCount) items from the album."
        guard let reason = results.first(where: { !$0.success })?.error else { return base }
        let readable = reason.replacingOccurrences(of: "_", with: " ")
        return "\(base) Server response: \(readable)."
    }

    // MARK: - bulk actions

    private func applyFavorite() async {
        guard await favorite(ids: Array(selection), value: true) else { return }
        exitSelection()
    }

    private func applyVisibility(_ value: AssetVisibility) async {
        guard await setVisibility(ids: Array(selection), value) else { return }
        exitSelection()
    }

    private func applyTrash() async {
        let selected = model.flatAssets.filter { selection.contains($0.id) && isSelectable($0) }
        guard await deleteAssets(selected, force: filter.isTrashed == true) else { return }
        exitSelection()
    }

    private func applyRestore() async {
        guard await restore(ids: Array(selection)) else { return }
        exitSelection()
    }

    private func applyRemoveFromAlbum() async {
        let removed = await removeFromAlbum(ids: Array(selection))
        selection.subtract(removed)
        if selection.isEmpty { exitSelection() }
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

private struct PreparedAssetShare: Identifiable {
    let id = UUID()
    let url: URL
}

/// UIKit owns context-menu actions, so their asynchronously prepared export is
/// handed to the system share controller through a small SwiftUI sheet bridge.
private struct TimelineShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: url)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
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
    let isWorking: Bool
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
                    barButton(
                        filter.visibility == .archive ? "tray.and.arrow.up" : "archivebox",
                        filter.visibility == .archive ? "Unarchive" : "Archive"
                    ) { Task { await onArchive() } }
                    barButton("rectangle.stack.badge.plus", "Album", action: onAddToAlbum)
                }
                barButton(
                    filter.isTrashed == true ? "trash.slash" : "trash",
                    filter.isTrashed == true ? "Delete" : "Trash",
                    role: .destructive
                ) { Task { await onTrash() } }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .disabled(isWorking || count == 0)
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
