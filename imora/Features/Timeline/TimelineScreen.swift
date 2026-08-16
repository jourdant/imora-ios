import SwiftUI

private struct TimelineScrollState: Equatable {
    let offsetY: CGFloat
    let insetTop: CGFloat
    let insetBottom: CGFloat
    let containerHeight: CGFloat
}

/// one month's slice of the grid in row space, newest first like the rows.
private struct ScrubberMonth {
    let id: String
    let title: String
    let year: Int
    let startY: CGFloat
    let height: CGFloat
    let firstRowID: String
    let firstRowIndex: Int
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
    /// resting position in raw offset terms, the floor a compensating scroll
    /// must not go below.
    var insetTop: CGFloat = 0
}

/// scroll-driven values live here instead of screen @state so per-frame
/// updates only re-render the scrubber overlay, never the whole grid body.
///
/// the indicator geometry below was measured empirically on ios 26: the
/// native track runs from the scroll view's own safe area top plus 3pt to
/// its bottom edge minus 3pt - it ignores the large-title expansion swiftui
/// reports in contentInsets.top - the overlay's own frame top sits at the
/// current inset, offsets are uikit style with 0 at rest meaning
/// offset+inset, and the thumb is bounds over virtual height with a 36pt
/// floor.
@Observable @MainActor
private final class ScrubberState {
    /// distance scrolled past the rest position at the top.
    var offsetY: CGFloat = 0
    var insetTop: CGFloat = 0
    var insetBottom: CGFloat = 0
    var containerHeight: CGFloat = 1
    /// the inset the indicator actually pins to: the COLLAPSED bar. sampled as
    /// the smallest contentInsets.top this scroll view has reported, because a
    /// large title inflates that inset while it is expanded even though the
    /// indicator track never moves with it. sampled rather than read from the
    /// scroll view's safeAreaInsets, which is not reliably the bar bottom -
    /// getting that wrong stretches the whole track and offsets every marker.
    /// one scrolled frame is enough to pin it, and the overlay is hidden until
    /// the user scrolls anyway.
    var compactInsetTop: CGFloat?
    /// scroll view height. a change means rotation, which invalidates the
    /// sampled inset - a landscape bar is shorter than a portrait one.
    private var frameHeight: CGFloat = 0
    var headerHeight: CGFloat = 0
    /// true only while the finger is dragging the thumb.
    var isScrubbing = false
    /// drag-driven position, so the thumb tracks the finger exactly instead of
    /// chasing the scroll it is causing.
    var scrubFraction: CGFloat?
    /// month layout in row space, rebuilt whenever the rows change shape - a
    /// bucket loading, a pinch resizing every tile.
    var liveMonths: [ScrubberMonth] = []
    /// total row height of `liveMonths`.
    var monthsHeight: CGFloat = 0
    /// empty space padded past the last row so the final month can reach the
    /// viewport top. scrollable content, so it counts toward the total.
    var tailPadding: CGFloat = 0
    /// held still for the length of a scrub, so a bucket landing mid-drag
    /// cannot spread the markers out under the finger.
    private var frozenMonths: [ScrubberMonth]?
    private var frozenTotal: CGFloat?

    var months: [ScrubberMonth] { frozenMonths ?? liveMonths }

    /// the app's OWN layout height - header, rows, tail padding - never the
    /// scroll view's reported contentSize. the rows are rendered from exactly
    /// this layout, so a month's offset here is its true content offset, which
    /// is what lets an absolute jump land on the month a marker names. immich
    /// does the same: its scrubber segments and its month jumps are both
    /// expressed in the timeline's own layout, not in scroll-view pixels.
    var contentTotal: CGFloat {
        frozenTotal ?? (headerHeight + monthsHeight + tailPadding)
    }

    func beginScrub() {
        frozenMonths = liveMonths
        frozenTotal = headerHeight + monthsHeight + tailPadding
        isScrubbing = true
    }

    func endScrub() {
        frozenMonths = nil
        frozenTotal = nil
        scrubFraction = nil
        isScrubbing = false
    }
    /// month of the row actually at the viewport top. ground truth, so the
    /// label never inherits the error in an unloaded month's estimated height.
    var visibleMonth: String?

    var scrollRange: CGFloat { max(0, contentTotal - containerHeight) }

    var fraction: CGFloat {
        if let scrubFraction { return scrubFraction }
        return scrollRange > 0 ? min(1, max(0, offsetY / scrollRange)) : 0
    }

    /// total scrollable span in uikit bounds coordinates.
    var virtualHeight: CGFloat { contentTotal + insetTop + insetBottom }


    /// indicator track in overlay coordinates. the overlay frame top sits at
    /// the current top inset, so pinning to the collapsed bar goes negative
    /// while the large title is expanded - exactly like the real indicator,
    /// which stays put while the title grows above it.
    var trackTop: CGFloat { (compactInsetTop ?? insetTop) + 3 - insetTop }

    /// the bottom end lands at the scroll view's own bottom edge less 3pt,
    /// which reduces to the container height whatever the insets are doing.
    var trackHeight: CGFloat { max(1, containerHeight - 3 - trackTop) }

    var thumbHeight: CGFloat {
        max(36, trackHeight * (containerHeight + insetTop + insetBottom) / max(1, virtualHeight))
    }

    var thumbCenterY: CGFloat {
        trackTop + fraction * (trackHeight - thumbHeight) + thumbHeight / 2
    }

    /// where a marker for content at `offset` belongs: literally `thumbCenterY`
    /// evaluated at that offset instead of the live one, so a marker and the
    /// thumb cannot disagree - same track, same travel, same clamped thumb.
    /// measuring markers against a snapshot of the layout while the thumb runs
    /// on the live one is what put them out of step, since an unloaded month
    /// is still an estimate and a pinch resizes every row underneath.
    func markerY(forContentOffset offset: CGFloat) -> CGFloat {
        guard scrollRange > 0 else { return trackTop }
        let progress = min(1, max(0, offset / scrollRange))
        return trackTop + progress * (trackHeight - thumbHeight) + thumbHeight / 2
    }

    func update(with state: TimelineScrollState) {
        // the scroll view's own height. only a rotation changes it, and the
        // bar it reported before that no longer applies.
        let frame = state.containerHeight + state.insetTop + state.insetBottom
        if abs(frame - frameHeight) > 0.5 {
            frameHeight = frame
            compactInsetTop = nil
        }
        if let sampled = compactInsetTop {
            if state.insetTop < sampled { compactInsetTop = state.insetTop }
        } else {
            compactInsetTop = state.insetTop
        }
        if insetTop != state.insetTop { insetTop = state.insetTop }
        if insetBottom != state.insetBottom { insetBottom = state.insetBottom }
        if containerHeight != state.containerHeight { containerHeight = state.containerHeight }
        if offsetY != state.offsetY { offsetY = state.offsetY }
    }

    /// month whose rows sit at the viewport top for a given offset, clamped
    /// to the newest month while the header is still on screen.
    func month(at offset: CGFloat) -> ScrubberMonth? {
        guard !months.isEmpty else { return nil }
        let rowY = offset - headerHeight
        var low = 0
        var high = months.count - 1
        var best = 0
        while low <= high {
            let mid = (low + high) / 2
            if months[mid].startY <= rowY + 1 {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return months[best]
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
    /// one-shot picker: while set, a tap hands the photo back instead of
    /// opening it, and nothing else on a tile responds. person pages choose a
    /// featured photo this way.
    var onPickAsset: ((Asset) -> Void)?
    @Binding private var serverCommand: TimelineServerCommand?
    let header: Header

    @State private var model: TimelineModel
    @State private var selection = Set<String>()
    @State private var isSelecting = false
    @State private var viewer = ViewerPresentation()
    /// the drawn indicator follows the system's own rhythm: it appears with a
    /// scroll and fades shortly after it stops. `grabbable` outlives the fade
    /// so a finger reaching for a thumb that has just faded still catches it.
    @State private var indicatorVisible = false
    @State private var indicatorGrabbable = false
    @State private var indicatorHideTask: Task<Void, Never>?
    /// last row a scrub jumped to, so a drag that stays inside one month does
    /// not re-issue the same scroll every frame. the sentinel stands for the
    /// very top, which is the header rather than any row.
    @State private var scrubbedRowID: String?
    private let scrubTopSentinel = "\u{0}top"
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
    /// Nil follows the width-aware default. Once the user pinches, retain
    /// their choice across window changes and only clamp the rendered value.
    @State private var preferredColumnCount: Int?
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
        onPickAsset: ((Asset) -> Void)? = nil,
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
        self.onPickAsset = onPickAsset
        _serverCommand = serverCommand
        self.header = header()
        _model = State(initialValue: TimelineModel(filter: filter, mergesLocal: mergesLocalPhotos))
    }

    private var isPicking: Bool { onPickAsset != nil }

    private func tileSide(for width: CGFloat) -> CGFloat {
        AssetGridLayout.tileSide(viewportWidth: width, columns: columnCount)
    }

    private func applyColumnCount(
        _ target: Int,
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        preservedFraction: CGFloat,
        recordsUserPreference: Bool
    ) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if recordsUserPreference { preferredColumnCount = target }
            columnCount = target
            model.columns = target
        }

        let newSide = AssetGridLayout.tileSide(
            viewportWidth: viewportWidth,
            columns: target
        )
        let contentHeight = scrub.headerHeight + model.contentHeight(tileSide: newSide)
            + endPadding(side: newSide, viewportHeight: viewportHeight)
        // raw contentOffset space, like every other scrollTo here.
        let offset = preservedFraction * max(0, contentHeight - viewportHeight) - scrub.insetTop
        // Wait for the rebuilt rows to enter layout before restoring position.
        Task { @MainActor in
            var scrollTransaction = Transaction()
            scrollTransaction.disablesAnimations = true
            withTransaction(scrollTransaction) {
                scrollPosition.scrollTo(y: offset)
            }
        }
    }

    /// pads the scroll bottom so the last month can reach the top of the
    /// viewport. without it the final screenful is unreachable: the oldest
    /// photos can never sit at the top, so the scrubber can never name them.
    private func endPadding(side: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        guard scrub.headerHeight + model.contentHeight(tileSide: side) > viewportHeight else { return 0 }
        let tail = model.sectionSpans.last.map {
            CGFloat($0.titleBands) * 36 + CGFloat($0.tileRows) * (side + 2)
        } ?? 0
        return max(0, (viewportHeight - tail).rounded())
    }

    var body: some View {
        GeometryReader { geometry in
            let side = tileSide(for: geometry.size.width)
            let tailPadding = endPadding(side: side, viewportHeight: geometry.size.height)

            ScrollView {
                // the header sits outside the lazy stack on purpose. every
                // marker position is measured from where row space starts, and
                // a header the lazy stack unmounts once it scrolls away stops
                // reporting its height - which would shift the whole rail.
                VStack(spacing: 0) {
                    VStack(spacing: 0) { header }
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height.rounded()
                        } action: { height in
                            if scrub.headerHeight != height { scrub.headerHeight = height }
                        }

                    LazyVStack(spacing: 0) {
                        ForEach(model.rows) { row in
                            rowView(row, side: side)
                                .id(row.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .padding(.bottom, (isSelecting ? 90 : 0) + tailPadding)
            }
            .scrollPosition($scrollPosition)
            // the drawn indicator is the app's own, so the system one would
            // only double it up.
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
                let insetTop = scroll.contentInsets.top
                return TimelineScrollState(
                    offsetY: max(0, ((scroll.contentOffset.y + insetTop) * 2).rounded() / 2),
                    insetTop: insetTop.rounded(),
                    insetBottom: scroll.contentInsets.bottom.rounded(),
                    containerHeight: max(1, scroll.containerSize.height.rounded())
                )
            } action: { _, state in
                scrub.update(with: state)
                scrollContext.insetTop = state.insetTop
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
                let range = AssetGridLayout.columnRange(viewportWidth: width)
                let target = preferredColumnCount.map {
                    min(range.upperBound, max(range.lowerBound, $0))
                } ?? AssetGridLayout.defaultColumnCount(viewportWidth: width)
                guard target != columnCount else { return }
                applyColumnCount(
                    target,
                    viewportWidth: width,
                    viewportHeight: geometry.size.height,
                    preservedFraction: scrub.fraction,
                    recordsUserPreference: false
                )
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
            // keyed on the row tallies, so any change of layout - a bucket
            // filling in, a pinch, a month appearing - re-measures the months.
            .onChange(of: ScrubberLayoutKey(model: model, side: side), initial: true) { _, _ in
                let months = Self.scrubberMonths(spans: model.sectionSpans, side: side)
                scrub.liveMonths = months
                scrub.monthsHeight = months.last.map { $0.startY + $0.height } ?? 0
            }
            .onChange(of: tailPadding, initial: true) { _, padding in
                scrub.tailPadding = padding
            }
            .onScrollPhaseChange { _, newPhase in
                scrollContext.isIdle = newPhase == .idle
                if newPhase == .idle {
                    scheduleIndicatorHide()
                } else {
                    showIndicator()
                }
            }
            .overlay(alignment: .topTrailing) {
                if model.rows.count > 30 && !viewer.isTransitioning {
                    TimelineScrubber(
                        scrub: scrub,
                        visible: indicatorVisible,
                        grabbable: indicatorGrabbable,
                        // scrolls by ROW identity. a pixel jump is clamped
                        // against whatever content height the lazy stack
                        // currently believes in, which is only exact for rows
                        // it has already realized, so a jump to the far end
                        // stops short of it. resolving down to the row rather
                        // than the month keeps the drag continuous inside a
                        // month, the way immich-web scrubs.
                        onScrub: { fraction in
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            guard let rowID = scrubTargetRow(fraction: fraction, side: side) else {
                                // above the first month lies the header, so the
                                // top of the drag means the top of the view.
                                guard scrubbedRowID != scrubTopSentinel else { return }
                                scrubbedRowID = scrubTopSentinel
                                withTransaction(transaction) { scrollPosition.scrollTo(edge: .top) }
                                return
                            }
                            guard rowID != scrubbedRowID else { return }
                            scrubbedRowID = rowID
                            withTransaction(transaction) {
                                scrollPosition.scrollTo(id: rowID, anchor: .top)
                            }
                        },
                        onScrubbingChanged: { scrubbing in
                            if scrubbing {
                                showIndicator()
                            } else {
                                scrubbedRowID = nil
                                scheduleIndicatorHide()
                            }
                            let apply = { scrubbing ? scrub.beginScrub() : scrub.endScrub() }
                            if reduceMotion {
                                apply()
                            } else {
                                withAnimation(.easeOut(duration: 0.15)) { apply() }
                            }
                        }
                    )
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(showsLargeTitle ? .large : .inline)
        .toolbar {
            if isSelecting, !isPicking {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { exitSelection() }
                        .disabled(isRunningServerCommand || !selection.isDisjoint(with: mutatingAssetIDs))
                }
            }
        }
        .overlay { overlayState }
        .overlay(alignment: .bottom) {
            if isSelecting, !isPicking {
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
        // a selection made before the mode began would come back with it.
        .onChange(of: isPicking) { _, picking in
            if picking { exitSelection() }
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
            let side = AssetGridLayout.tileSide(
                viewportWidth: context.viewportWidth,
                columns: model.columns
            )
            if let oldStart = TimelineModel.rowStart(of: anchor, in: old, tileSide: side),
               let newStart = TimelineModel.rowStart(of: anchor, in: new, tileSide: side),
               abs(newStart - oldStart) > 0.5 {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    apply()
                    position.wrappedValue.scrollTo(
                        y: max(-context.insetTop, context.offsetY + newStart - oldStart)
                    )
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

        case .placeholder(_, let bucketID, let tileRows, let titleBands):
            PlaceholderGrid(tileRows: tileRows, titleBands: titleBands, columns: columnCount, side: side)
                // debounced rows: a synchronous rebuild here changes content
                // heights inside the scroll pass that revealed the
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
        // picking wants one photo and nothing else, so a tile carries neither
        // the long-press menu nor a viewer of its own while the mode is on.
        if let onPickAsset {
            AssetTile(asset: asset, showsBackupBadge: mergesLocalPhotos)
                .onTapGesture { onPickAsset(asset) }
        // selection mode keeps taps as the only gesture, like the system
        // photos app.
        } else if isSelecting {
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
                let range = AssetGridLayout.columnRange(viewportWidth: viewportWidth)
                let target = min(
                    range.upperBound,
                    max(range.lowerBound, Int((Double(base) / value.magnification).rounded()))
                )
                guard target != columnCount else { return }

                let preservedFraction = scrub.fraction
                let generator = UISelectionFeedbackGenerator()
                generator.selectionChanged()

                applyColumnCount(
                    target,
                    viewportWidth: viewportWidth,
                    viewportHeight: viewportHeight,
                    preservedFraction: preservedFraction,
                    recordsUserPreference: true
                )
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
            personID: filter.personId,
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
        indicatorHideTask?.cancel()
        indicatorHideTask = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrub.endScrub()
            indicatorVisible = false
            indicatorGrabbable = false
        }
    }

    private func showIndicator() {
        guard !viewer.isTransitioning else { return }
        indicatorHideTask?.cancel()
        indicatorHideTask = nil
        indicatorGrabbable = true
        if reduceMotion {
            indicatorVisible = true
        } else {
            withAnimation(.easeOut(duration: 0.12)) { indicatorVisible = true }
        }
    }

    private func scheduleIndicatorHide() {
        guard !viewer.isTransitioning else { return }
        indicatorHideTask?.cancel()
        indicatorHideTask = Task {
            try? await Task.sleep(for: .milliseconds(1_100))
            guard !Task.isCancelled, !scrub.isScrubbing else { return }
            if reduceMotion {
                indicatorVisible = false
            } else {
                withAnimation(.easeOut(duration: 0.25)) { indicatorVisible = false }
            }
            // grace window: the thumb is gone but still catchable, so reaching
            // for it right after it fades does not scroll the grid instead.
            try? await Task.sleep(for: .milliseconds(2_500))
            guard !Task.isCancelled, !scrub.isScrubbing else { return }
            indicatorGrabbable = false
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

    /// row the scrubber is pointing at, found by walking forward from its
    /// month's first row - a handful of steps, since the month containing the
    /// target is already known. nil means the drag is above the first month,
    /// where only the header lives.
    private func scrubTargetRow(fraction: CGFloat, side: CGFloat) -> String? {
        let target = fraction * scrub.scrollRange
        guard target >= scrub.headerHeight, let month = scrub.month(at: target) else { return nil }
        let rows = model.rows
        // the frozen month indexes the rows as they were when the drag began;
        // if a rebuild has landed since, the month's own row is still right.
        guard month.firstRowIndex < rows.count,
              rows[month.firstRowIndex].id == month.firstRowID
        else { return month.firstRowID }

        var y = scrub.headerHeight + month.startY
        var index = month.firstRowIndex
        var rowID = month.firstRowID
        while index < rows.count {
            let height = rows[index].height(tileSide: side)
            rowID = rows[index].id
            if y + height > target { break }
            y += height
            index += 1
        }
        return rowID
    }

    private static func scrubberMonths(spans: [TimelineSectionSpan], side: CGFloat) -> [ScrubberMonth] {
        var y: CGFloat = 0
        return spans.map { span in
            let height = CGFloat(span.titleBands) * 36 + CGFloat(span.tileRows) * (side + 2)
            defer { y += height }
            return ScrubberMonth(
                id: span.id,
                title: span.title,
                year: span.year,
                startY: y,
                height: height,
                firstRowID: span.firstRowID,
                firstRowIndex: span.firstRowIndex
            )
        }
    }
}

/// every input to the month layout, in o(1): the two row tallies move whenever
/// any month's height does, and the ends catch a month appearing or leaving.
private struct ScrubberLayoutKey: Equatable {
    let titleBands: Int
    let tileRows: Int
    let count: Int
    let first: String?
    let last: String?
    let side: CGFloat

    init(model: TimelineModel, side: CGFloat) {
        titleBands = model.titleBandCount
        tileRows = model.tileRowCount
        count = model.sectionSpans.count
        first = model.sectionSpans.first?.id
        last = model.sectionSpans.last?.id
        self.side = side
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

/// dimmed grid pattern shown while a bucket loads. fixed height by construction,
/// day-title bands included, so the month keeps its place once it loads.
private struct PlaceholderGrid: View {
    let tileRows: Int
    let titleBands: Int
    let columns: Int
    let side: CGFloat

    var body: some View {
        // draw at most a screenful of visible squares; the rest is one flat block.
        let visibleRows = min(tileRows, 12)
        let visibleBands = min(titleBands, max(1, visibleRows / 2))
        let rowsPerBand = max(1, visibleRows / max(1, visibleBands))
        VStack(spacing: 2) {
            ForEach(0..<visibleRows, id: \.self) { row in
                if row % rowsPerBand == 0, row / rowsPerBand < visibleBands {
                    // 34 not 36: the stack's own 2pt spacing completes a band.
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.secondarySystemFill))
                        .frame(width: 96, height: 14)
                        .padding(.leading, 4)
                        .padding(.bottom, 5)
                        .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .bottomLeading)
                }
                HStack(spacing: 2) {
                    ForEach(0..<columns, id: \.self) { _ in
                        Rectangle()
                            .fill(Color(.secondarySystemFill))
                            .frame(width: side, height: side)
                    }
                }
            }
            let remainingHeight = CGFloat(tileRows - visibleRows) * (side + 2)
                + CGFloat(titleBands - visibleBands) * 36
            if remainingHeight > 2 {
                Rectangle()
                    .fill(Color(.secondarySystemFill).opacity(0.6))
                    .frame(height: remainingHeight - 2)
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

/// scroll indicator drawn by the app, sized and placed exactly like the system
/// one, plus the immich-web style marker rail and date pill that appear while
/// it is held.
///
/// the system indicator cannot be used for this: nothing in uikit or swiftui
/// reports when the user grabs it. UIScrollView exposes only its pan and pinch
/// recognizers - the indicator's own recognizer and view are private -
/// UIScrollViewDelegate has no callback for it, and during such a drag only
/// scrollViewDidScroll fires, which is indistinguishable from a programmatic
/// scroll. so the app owns the thumb, and the system's is hidden.
private struct TimelineScrubber: View {
    let scrub: ScrubberState
    let visible: Bool
    let grabbable: Bool
    let onScrub: (CGFloat) -> Void
    let onScrubbingChanged: (Bool) -> Void

    /// where the finger sat inside the thumb when it was grabbed, so the thumb
    /// never jumps under it.
    @State private var grabOffset: CGFloat = 0

    private static let space = "timeline-scrubber-track"
    /// system metrics: a hairline capsule 4.5pt in from the trailing edge,
    /// thickening while held.
    private var thumbWidth: CGFloat { scrub.isScrubbing ? 6 : 3.5 }
    /// generous next to a 3.5pt thumb, and it only covers the thumb, so an
    /// ordinary swipe anywhere else along the edge still scrolls the grid.
    private var grabHeight: CGFloat { max(48, scrub.thumbHeight + 20) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if scrub.isScrubbing {
                    ScrubberMarkerRail(scrub: scrub)
                        .transition(.opacity)
                    ScrubberMonthLabel(scrub: scrub)
                        .transition(.opacity)
                }

                if visible || scrub.isScrubbing {
                    Capsule()
                        .fill(Color(.label).opacity(scrub.isScrubbing ? 0.5 : 0.35))
                        .frame(width: thumbWidth, height: scrub.thumbHeight)
                        .padding(.trailing, 4.5 - thumbWidth / 2)
                        .offset(y: scrub.thumbCenterY - scrub.thumbHeight / 2)
                        .animation(.snappy(duration: 0.18), value: scrub.isScrubbing)
                        .transition(.opacity)
                }
            }
            // only the grab handle below takes touches; the drawn parts must
            // never swallow a tap meant for a photo.
            .allowsHitTesting(false)

            Color.clear
                .frame(width: 44, height: grabHeight)
                .contentShape(.rect)
                .offset(y: scrub.thumbCenterY - grabHeight / 2)
                .gesture(drag)
                .allowsHitTesting(grabbable || scrub.isScrubbing)
                .accessibilityIdentifier("timeline-scrubber")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .coordinateSpace(.named(Self.space))
        .accessibilityHidden(true)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if !scrub.isScrubbing {
                    grabOffset = value.startLocation.y - scrub.thumbCenterY
                    onScrubbingChanged(true)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                let travel = max(1, scrub.trackHeight - scrub.thumbHeight)
                let centre = value.location.y - grabOffset
                let raw = (centre - scrub.thumbHeight / 2 - scrub.trackTop) / travel
                // quantized and deduped so coalesced touch samples collapse to
                // one scroll write per frame.
                let fraction = (min(1, max(0, raw)) * 1_000).rounded() / 1_000
                guard fraction != scrub.scrubFraction else { return }
                scrub.scrubFraction = fraction
                onScrub(fraction)
            }
            .onEnded { _ in onScrubbingChanged(false) }
    }
}

/// year labels at year boundaries and dots for months, spaced with the
/// minimum-distance rules immich-web uses and placed with the same mapping
/// the indicator thumb sweeps.
private struct ScrubberMarkerRail: View {
    let scrub: ScrubberState

    private struct RailMark: Identifiable {
        let id: String
        let y: CGFloat
        let year: String?
        let hasDot: Bool
    }

    var body: some View {
        GlassEffectContainer {
            ZStack(alignment: .topTrailing) {
                ForEach(railMarks()) { mark in
                    if let year = mark.year {
                        Text(year)
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .glassEffect(.regular, in: .capsule)
                            .frame(height: 18)
                            .padding(.trailing, 12)
                            .offset(y: mark.y - 9)
                    }
                    if mark.hasDot {
                        // centred on the indicator's own line, measured at
                        // 4.5pt in from the trailing edge. the overlay cannot
                        // draw under a uikit indicator, so sharing the column
                        // is as layered as the two can get.
                        Circle()
                            .fill(.white)
                            .frame(width: 4, height: 4)
                            .shadow(color: .black.opacity(0.4), radius: 1)
                            .padding(.trailing, 2.5)
                            .offset(y: mark.y - 2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    /// months are walked oldest first, like immich-web, so a year is named at
    /// the month it begins with in time - january - and not at the newest
    /// month the year happens to end on. the newest year therefore has no chip
    /// at the very top of the rail; its chip sits down where that year started.
    /// the chip anchors to the top edge of that january rather than the web's
    /// bottom edge, which is the one point of difference: it puts the mark on
    /// the same content the pill names when the two meet.
    ///
    /// immich-web's thresholds - 16pt between year labels, 8pt between dots,
    /// months thinner than 5pt get no dot - are applied as a DROP rule rather
    /// than the web's carry-forward. the web tracks the span since the last
    /// label and lets a LATER month claim the year once the span is big
    /// enough, which parks the chip months away from the year it names. here a
    /// mark is either exactly on the boundary it names or absent.
    private func railMarks() -> [RailMark] {
        let months = scrub.months
        guard !months.isEmpty, scrub.trackHeight > 1, scrub.scrollRange > 0 else { return [] }
        var marks: [RailMark] = []
        var previousYear: Int?
        // walking oldest first means positions climb the rail, so the spacing
        // rules compare against a value that decreases.
        var lastLabelY = CGFloat.greatestFiniteMagnitude
        var lastDotY = CGFloat.greatestFiniteMagnitude
        for month in months.reversed() {
            let monthStart = scrub.headerHeight + month.startY
            let startY = scrub.markerY(forContentOffset: monthStart)
            let height = scrub.markerY(forContentOffset: monthStart + month.height) - startY
            let opensYear = previousYear != month.year
            previousYear = month.year

            var year: String?
            if opensYear, lastLabelY - startY > 16 {
                year = String(month.year)
                lastLabelY = startY
            }
            var hasDot = false
            if height > 5, lastDotY - startY > 8 {
                hasDot = true
                lastDotY = startY
            }
            if year != nil || hasDot {
                marks.append(RailMark(id: month.id, y: startY, year: year, hasDot: hasDot))
            }
        }
        return marks
    }
}

/// floating month pill riding the indicator thumb, naming whatever month
/// sits at the viewport top. the overlay it belongs to only exists during a
/// scrub, so no further gate is needed here.
private struct ScrubberMonthLabel: View {
    let scrub: ScrubberState

    var body: some View {
        if scrub.scrollRange > 0,
           let title = scrub.visibleMonth ?? scrub.month(at: scrub.offsetY)?.title {
            // drawn after the rail in the overlay zstack, so it passes over
            // the markers while hugging the indicator.
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: .capsule)
                .frame(height: 34)
                .padding(.trailing, 10)
                .offset(y: scrub.thumbCenterY - 17)
                .transition(.opacity)
                .accessibilityIdentifier("timeline-scrubber-label")
                .onChange(of: title) {
                    UISelectionFeedbackGenerator().selectionChanged()
                }
        }
    }
}
