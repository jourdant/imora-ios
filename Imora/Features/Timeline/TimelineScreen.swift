import SwiftUI

private struct TimelineScrollState: Equatable {
    let offsetY: CGFloat
    let indicatorOffsetY: CGFloat
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
}

/// plain box written from scroll callbacks and read when a realtime rows
/// update lands. nothing here is observed, so per-frame writes never
/// re-render anything.
@MainActor
private final class ScrollContext {
    /// distance scrolled past the rest position, the space scrollTo(y:) takes.
    var offsetY: CGFloat = 0
    var firstVisibleRowID: String?
    /// the whole visible run, not just the first row: only tile rows anchor a
    /// prefetch window and the top row is usually a month header.
    var visibleRowIDs: [String] = []
    /// same rows as indices, the cheap equality check behind the ids above.
    var visibleRange: Range<Int> = 0..<0
    /// the rows layout the ids were read from. a swap can leave the indices
    /// alone while every row behind them is new.
    var visibleLayoutVersion = -1
    var isIdle = true
    var viewportWidth: CGFloat = 0
    var viewportHeight: CGFloat = 0
}

/// exact top offset of every row, in row space. deterministic row heights
/// make this a plain prefix sum, rebuilt only when the rows or the tile side
/// change.
private struct RowLayout {
    let version: Int
    let side: CGFloat
    let starts: [CGFloat]
    let total: CGFloat

    static let empty = RowLayout(version: -1, side: 0, starts: [], total: 0)

    static func build(rows: [TimelineRow], side: CGFloat, version: Int) -> RowLayout {
        var starts: [CGFloat] = []
        starts.reserveCapacity(rows.count)
        var y: CGFloat = 0
        for row in rows {
            starts.append(y)
            y += row.height(tileSide: side)
        }
        return RowLayout(version: version, side: side, starts: starts, total: y)
    }

    /// index of the row whose span contains `y`, clamped to the ends.
    func index(at y: CGFloat) -> Int {
        var low = 0
        var high = starts.count - 1
        var best = 0
        while low <= high {
            let mid = (low + high) / 2
            if starts[mid] <= y {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }
}

/// plain cache for the layout above; nothing observed, mutated freely from
/// scroll callbacks and body alike.
@MainActor
private final class RowLayoutBox {
    var layout = RowLayout.empty
}

/// the mounted row range of the virtual stack. observable so a window slide
/// re-renders only the stack, never the screen.
@Observable @MainActor
private final class RowWindow {
    var range: Range<Int> = 0..<0
}

/// how far past the viewport rows stay mounted, so a swipe reveals content
/// that already exists and placeholder onAppear loads run ahead of arrival.
private let rowWindowBuffer: CGFloat = 360

/// the app's own lazy stack, replacing LazyVStack: every mounted row is
/// placed at its exact offset inside a frame of exactly the layout's total
/// height. immich-web does precisely this - its scroll container is styled to
/// totalViewerHeight and each month is position:absolute at its computed top,
/// with only intersecting months mounted.
///
/// LazyVStack could not be kept: it reports a contentSize INTERPOLATED from
/// whichever rows it happens to have realized - measured 15% long at library
/// scale on ios 27 - and it also POSITIONS unrealized rows in that estimated
/// space, so pinning its frame to the true height strands the tail out of
/// reach. with the stack owning both the height and every row position there
/// is a single coordinate space: contentSize, scrollTo(y:), the scrubber rail
/// and the realtime scroll compensation all agree by construction.
private struct VirtualRowStack<Content: View>: View {
    let rows: [TimelineRow]
    let starts: [CGFloat]
    let totalHeight: CGFloat
    let window: RowWindow
    @ViewBuilder let content: (Int, TimelineRow) -> Content

    var body: some View {
        let count = min(rows.count, starts.count)
        let range = window.range.clamped(to: 0..<count)
        let items = range.map { (index: $0, row: rows[$0]) }
        ZStack(alignment: .top) {
            // top padding, not offset, so each row stays in layout at its true
            // position and hit testing needs no transforms - the same trick the
            // rows use horizontally.
            ForEach(items, id: \.row.id) { item in
                content(item.index, item.row)
                    .padding(.top, starts[item.index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(height: max(1, totalHeight), alignment: .top)
    }
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
    /// the drawn indicator follows the system's own rhythm: it appears with a
    /// scroll and fades shortly after it stops. `grabbable` outlives the fade
    /// so a finger reaching for a thumb that has just faded still catches it.
    ///
    /// they live here rather than in screen @state because they flip on every
    /// scroll phase change - three times a fling - and a screen-level write
    /// would re-run the grid body, and its every visible tile, each time.
    var indicatorVisible = false
    var indicatorGrabbable = false
    /// drag-driven position, so the thumb tracks the finger exactly instead of
    /// chasing the scroll it is causing.
    var scrubFraction: CGFloat?
    /// month layout in row space, rebuilt whenever the rows change shape - a
    /// bucket loading, a pinch resizing every tile.
    var liveMonths: [ScrubberMonth] = []
    /// total row height of `liveMonths`.
    var monthsHeight: CGFloat = 0
    /// empty space padded past the last row - the selection bar's clearance,
    /// nothing else. scrollable content, so it counts toward the total.
    var tailPadding: CGFloat = 0
    /// held still for the length of a scrub, so a bucket landing mid-drag
    /// cannot spread the markers out under the finger.
    private var frozenMonths: [ScrubberMonth]?
    private var frozenTotal: CGFloat?

    var months: [ScrubberMonth] { frozenMonths ?? liveMonths }

    /// the app's OWN layout height - header, rows, bottom padding. the
    /// virtual stack places every row from exactly this layout, so it IS the
    /// scroll view's contentSize and every value derived from it is a real
    /// scroll offset. immich-web's totalViewerHeight, one to one.
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

    /// how much of the content the viewport top can actually reach, as a
    /// fraction of the whole - immich-web's maxScrollPercent. the last
    /// viewport-height of any timeline can never sit at the top, so the rail
    /// spans the FULL content while a drag only ever asks for a reachable
    /// offset. this is what the web uses instead of padding the end, and it is
    /// why nothing can pin: an offset that is already inside the scrollable
    /// range cannot be clamped short of itself.
    var maxScrollPercent: CGFloat {
        contentTotal > 0 ? scrollRange / contentTotal : 0
    }

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

    /// where a marker for content at `offset` belongs. the rail is laid out
    /// over the WHOLE content - immich-web's segmentTop / totalHeight - while
    /// the thumb rides offsetY / scrollRange, and the two meet exactly because
    /// a drag scrolls to offset * maxScrollPercent. measuring markers against
    /// the scroll range instead put the oldest month's chip at the very bottom
    /// of the track and asked a drag there to place that month at the viewport
    /// top, which only a viewport of padding can satisfy and which clamped
    /// short whenever it did not - the grid pinned a year early while the thumb
    /// kept travelling.
    func markerY(forContentOffset offset: CGFloat) -> CGFloat {
        guard contentTotal > 0 else { return trackTop }
        let progress = min(1, max(0, offset / contentTotal))
        return trackTop + progress * (trackHeight - thumbHeight) + thumbHeight / 2
    }

    /// content offset a drag at `fraction` scrolls to: immich-web's
    /// (segmentTop + delta) * maxScrollPercent, reduced. always inside the
    /// scrollable range, so nothing ever clamps or springs back.
    func contentOffset(forFraction fraction: CGFloat) -> CGFloat {
        min(1, max(0, fraction)) * scrollRange
    }

    /// month the RAIL points at, which is what the floating pill names while a
    /// drag is on. the web reads its label from the same scaled walk that
    /// places the markers, so pill and chip always agree; the month actually at
    /// the viewport top can be up to a viewport newer near the end, which is
    /// inherent to mapping a full timeline onto a shorter scrollable range.
    func month(atFraction fraction: CGFloat) -> ScrubberMonth? {
        month(at: min(1, max(0, fraction)) * contentTotal)
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
        if offsetY != state.indicatorOffsetY { offsetY = state.indicatorOffsetY }
    }

    /// every input `railMarks` reads. the thumb moves every frame of a drag but
    /// none of this does, so the rail is computed once and handed back.
    private struct RailKey: Equatable {
        let count: Int
        let first: String?
        let last: String?
        let monthsHeight: CGFloat
        let headerHeight: CGFloat
        let trackTop: CGFloat
        let trackHeight: CGFloat
        let thumbHeight: CGFloat
        let scrollRange: CGFloat
    }

    @ObservationIgnored private var railCache: (key: RailKey, marks: [ScrubberRailMark])?

    /// months are walked oldest first, like immich-web, so a year is named at
    /// the month it begins with in time - january - and not at the newest
    /// month the year happens to end on. the newest year therefore has no chip
    /// at the very top of the rail; its chip sits down where that year started.
    ///
    /// chips and dots anchor at the BOTTOM edge of their month's segment,
    /// exactly like the web, whose label and dot divs are both absolute
    /// bottom-0 inside the segment. the bottom edge is the month's start in
    /// time - a january segment runs jan 31 at its top down to jan 1 at its
    /// bottom - so the year chip sits on the year's very first photo.
    /// anchoring at the top edge instead put every chip a whole january too
    /// new. the anchor pulls in 2pt so the boundary pixel still resolves to
    /// the month the mark names rather than to december of the year below,
    /// mirroring how the web's boundary pixel belongs to the january div.
    ///
    /// immich-web's thresholds - 16pt between year labels, 8pt between dots,
    /// months thinner than 5pt get no dot, the oldest month always gets both -
    /// are applied as a DROP rule rather than the web's carry-forward. the web
    /// tracks the span since the last label and lets a LATER month claim the
    /// year once the span is big enough, which parks the chip months away from
    /// the year it names. here a mark is either exactly on the boundary it
    /// names or absent.
    func railMarks() -> [ScrubberRailMark] {
        let months = months
        let key = RailKey(
            count: months.count,
            first: months.first?.id,
            last: months.last?.id,
            monthsHeight: monthsHeight,
            headerHeight: headerHeight,
            trackTop: trackTop,
            trackHeight: trackHeight,
            thumbHeight: thumbHeight,
            scrollRange: scrollRange
        )
        if let railCache, railCache.key == key { return railCache.marks }

        var marks: [ScrubberRailMark] = []
        if !months.isEmpty, trackHeight > 1, scrollRange > 0 {
            var previousYear: Int?
            var isOldest = true
            // walking oldest first means positions climb the rail, so the
            // spacing rules compare against a value that decreases.
            var lastLabelY = CGFloat.greatestFiniteMagnitude
            var lastDotY = CGFloat.greatestFiniteMagnitude
            for month in months.reversed() {
                let monthStart = headerHeight + month.startY
                let markY = markerY(forContentOffset: monthStart + month.height - 2)
                let height = markY - markerY(forContentOffset: monthStart)
                let opensYear = previousYear != month.year
                previousYear = month.year

                var year: String?
                if opensYear, lastLabelY - markY > 16 {
                    year = String(month.year)
                    lastLabelY = markY
                }
                var hasDot = false
                if isOldest || (height > 5 && lastDotY - markY > 8) {
                    hasDot = true
                    lastDotY = markY
                }
                isOldest = false
                if year != nil || hasDot {
                    marks.append(ScrubberRailMark(id: month.id, y: markY, year: year, hasDot: hasDot))
                }
            }
        }
        railCache = (key, marks)
        return marks
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
struct TimelineScreen<Header: View, Trailing: ToolbarContent>: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
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
    @Binding private var navigationTarget: TimelineNavigationTarget?
    @Binding private var serverCommand: TimelineServerCommand?
    let header: Header
    /// the host's own trailing navigation items. they are declared here
    /// rather than on the host so this screen owns the whole trailing group:
    /// the select pill always leads them, and selection mode unmounts them
    /// in place - a host-side toolbar would merge ahead of anything added
    /// from inside.
    let trailingItems: Trailing

    @State private var model: TimelineModel
    @State private var selection = Set<String>()
    @State private var isSelecting = false
    @State private var viewer = ViewerPresentation()
    @State private var indicatorHideTask: Task<Void, Never>?
    /// tracks `scrub.isScrubbing` but is written outside its animation, since
    /// this one decides which kind of tile the grid is built from.
    @State private var isScrubbingTiles = false
    @State private var scrub = ScrubberState()
    @State private var scrollContext = ScrollContext()
    @State private var rowWindow = RowWindow()
    @State private var rowLayoutBox = RowLayoutBox()
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var openingChromePrewarmOwner = UUID()
    @State private var pendingAlbumAssets: [String]?
    @State private var pendingEditAsset: Asset?
    @State private var shareRequest: AssetShareRequest?
    /// frozen at the moment the pill is tapped, so the sheet's grid holds
    /// still while items are unchecked inside it.
    @State private var selectedSheetAssets: [Asset] = []
    @State private var showsSelectedSheet = false
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
    @State private var selectionSlideController = TimelineSelectionSlideController()
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
        navigationTarget: Binding<TimelineNavigationTarget?> = .constant(nil),
        serverCommand: Binding<TimelineServerCommand?> = .constant(nil),
        @ToolbarContentBuilder trailingItems: () -> Trailing = {
            ToolbarItemGroup(placement: .topBarTrailing) {}
        },
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
        _navigationTarget = navigationTarget
        _serverCommand = serverCommand
        self.trailingItems = trailingItems()
        self.header = header()
        _model = State(initialValue: TimelineModel(filter: filter, mergesLocal: mergesLocalPhotos))
    }

    private var isPicking: Bool { onPickAsset != nil }

    /// the default builder hands back an empty group, and a spacer next to
    /// nothing would only push the select pill inward.
    private var hasTrailingItems: Bool {
        Trailing.self != ToolbarItemGroup<EmptyView>.self
    }

    private func tileSide(for width: CGFloat) -> CGFloat {
        AssetGridLayout.tileSide(viewportWidth: width, columns: columnCount)
    }

    private func thumbnailPixelSize(for side: CGFloat) -> CGFloat {
        let pixels = max(1, side * displayScale)
        return min(1_280, (pixels / 32).rounded(.up) * 32)
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
        let contentHeight = scrub.headerHeight + model.contentHeight(tileSide: newSide) + bottomPadding()
        // distance past the rest position, the space scrollTo(y:) takes.
        let offset = preservedFraction * max(0, contentHeight - viewportHeight)
        // Wait for the rebuilt rows to enter layout before restoring position.
        Task { @MainActor in
            var scrollTransaction = Transaction()
            scrollTransaction.disablesAnimations = true
            withTransaction(scrollTransaction) {
                scrollPosition.scrollTo(y: offset)
            }
        }
    }

    /// content is taller than the viewport, so there is a scrollbar to draw.
    private func isScrollable(rowsHeight: CGFloat, viewportHeight: CGFloat) -> Bool {
        scrub.headerHeight + rowsHeight > viewportHeight
    }

    /// the cached exact row offsets, rebuilt when the rows or the side moved.
    private func rowLayout(side: CGFloat) -> RowLayout {
        let box = rowLayoutBox
        if box.layout.version != model.rowsLayoutVersion || box.layout.side != side {
            box.layout = RowLayout.build(rows: model.rows, side: side, version: model.rowsLayoutVersion)
        }
        return box.layout
    }

    /// recomputes what the viewport sees and what the stack keeps mounted,
    /// from the exact layout. runs on every scroll frame - two binary searches
    /// and integer compares - and writes the observable window only when the
    /// mounted range actually moves.
    private func updateRowWindow() {
        let context = scrollContext
        guard context.viewportWidth > 0, context.viewportHeight > 0 else { return }
        let side = tileSide(for: context.viewportWidth)
        let layout = rowLayout(side: side)
        let rows = model.rows
        let count = min(rows.count, layout.starts.count)
        guard count > 0 else {
            if !rowWindow.range.isEmpty { rowWindow.range = 0..<0 }
            return
        }
        let top = context.offsetY - scrub.headerHeight

        let visibleLow = min(layout.index(at: top), count - 1)
        let visibleHigh = min(layout.index(at: top + context.viewportHeight), count - 1) + 1
        let visible = visibleLow..<visibleHigh
        // refreshed on every rows swap, not only when the range moves: a
        // bucket landing keeps the same indices while the rows behind them
        // are all new, and stale ids would anchor the prefetch window and the
        // scroll compensation to rows that no longer exist.
        if visible != context.visibleRange || context.visibleLayoutVersion != layout.version {
            context.visibleRange = visible
            context.visibleLayoutVersion = layout.version
            context.firstVisibleRowID = rows[visibleLow].id
            context.visibleRowIDs = rows[visible].map(\.id)
            // a scrub lands somewhere else every frame, and warming eighty
            // tiles at each stop only queues work the next frame throws away.
            // the window is rebuilt once the finger lifts.
            if !scrub.isScrubbing {
                prefetcher.update(
                    visibleRowIDs: context.visibleRowIDs,
                    model: model,
                    client: session.client,
                    backup: session.backup,
                    targetPixelSize: thumbnailPixelSize(for: side)
                )
            }
        }
        prewarmOpeningChrome(in: rows, visibleRange: visible)

        let mountedLow = min(layout.index(at: top - rowWindowBuffer), count - 1)
        let mountedHigh = min(layout.index(at: top + context.viewportHeight + rowWindowBuffer), count - 1) + 1
        let mounted = mountedLow..<mountedHigh
        if mounted != rowWindow.range { rowWindow.range = mounted }
    }

    private func prewarmOpeningChrome(
        in rows: [TimelineRow],
        visibleRange: Range<Int>
    ) {
        guard scrollContext.isIdle,
              !scrub.isScrubbing,
              pinchBaseColumns == nil,
              !isSelecting,
              !isPicking,
              !viewer.isTransitioning
        else { return }
        let center = CGFloat(visibleRange.lowerBound + visibleRange.upperBound - 1) / 2
        let prioritizedIndices = visibleRange.sorted {
            abs(CGFloat($0) - center) < abs(CGFloat($1) - center)
        }
        let assets = prioritizedIndices.flatMap { index -> [Asset] in
            let row = rows[index]
            guard case .tiles(_, let runs) = row else { return [] }
            return runs.flatMap(\.assets)
        }
        AssetViewerOpeningChromeCache.shared.prewarm(
            owner: openingChromePrewarmOwner,
            assets: assets,
            session: session
        )
    }

    /// everything padded past the last row, which is only the selection bar's
    /// clearance. there is deliberately NO viewport-sized tail: padding the end
    /// so the last month can reach the viewport top is what made a drag there
    /// depend on a full screen of empty content being present to the pixel, and
    /// it clamped short whenever the scroll view disagreed. immich-web pads
    /// nothing and compresses the mapping instead - see maxScrollPercent - so
    /// the end of the track is simply the end of the scroll.
    private func bottomPadding() -> CGFloat {
        isSelecting ? 90 : 0
    }

    var body: some View {
        GeometryReader { geometry in
            let side = tileSide(for: geometry.size.width)
            let layout = rowLayout(side: side)
            let scrollable = isScrollable(rowsHeight: layout.total, viewportHeight: geometry.size.height)
            let tailPadding = bottomPadding()

            ScrollView {
                // the header sits above the virtual stack; every marker
                // position is measured from where row space starts, so its
                // height is measured rather than assumed.
                VStack(spacing: 0) {
                    VStack(spacing: 0) { header }
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height.rounded()
                        } action: { height in
                            if scrub.headerHeight != height {
                                scrub.headerHeight = height
                                updateRowWindow()
                            }
                        }

                    VirtualRowStack(
                        rows: model.rows,
                        starts: layout.starts,
                        totalHeight: layout.total,
                        window: rowWindow
                    ) { rowIndex, row in
                        rowView(row, rowIndex: rowIndex, side: side)
                    }
                }
                .background {
                    TimelineSelectionSlideInstaller(
                        controller: selectionSlideController,
                        isEnabled: isSelecting && !isPicking,
                        selectedIDs: selection,
                        assetIDsInRectangle: selectableAssetIDs,
                        applyChanges: applySelectionRectangle,
                        onActiveChanged: handleSelectionSlideActivity
                    )
                }
                .padding(.bottom, tailPadding)
            }
            .scrollPosition($scrollPosition)
            // the drawn indicator is the app's own, so the system one would
            // only double it up.
            .scrollIndicators(.hidden)
            .simultaneousGesture(
                pinchGesture(
                    viewportWidth: geometry.size.width,
                    viewportHeight: geometry.size.height
                )
            )
            .onScrollGeometryChange(for: TimelineScrollState.self) { scroll in
                // the indicator is rounded to suppress sub point drawing noise,
                // while row windowing keeps the precise offset.
                let insetTop = scroll.contentInsets.top
                let offsetY = scroll.contentOffset.y + insetTop
                return TimelineScrollState(
                    offsetY: offsetY,
                    indicatorOffsetY: max(0, (offsetY * 2).rounded() / 2),
                    insetTop: insetTop.rounded(),
                    insetBottom: scroll.contentInsets.bottom.rounded(),
                    containerHeight: max(1, scroll.containerSize.height.rounded())
                )
            } action: { _, state in
                scrub.update(with: state)
                scrollContext.offsetY = state.offsetY
                updateRowWindow()
            }
            .onChange(of: geometry.size.height, initial: true) { _, height in
                scrollContext.viewportHeight = height
                updateRowWindow()
            }
            .onChange(of: geometry.size.width, initial: true) { _, width in
                scrollContext.viewportWidth = width
                // whichever of the initial callbacks lands last completes
                // the viewport, so each one windows the rows.
                updateRowWindow()
                if navigationTarget != nil {
                    Task { await revealPendingTimelineTarget() }
                }
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
                    backup: session.backup,
                    targetPixelSize: thumbnailPixelSize(for: side)
                )
            }
            // keyed on the row tallies and the layout version, so any change
            // of layout - a bucket filling in, a pinch, a month appearing -
            // re-measures the months and re-windows the rows, which may have
            // shifted under a fixed scroll offset.
            .onChange(of: ScrubberLayoutKey(model: model, side: side), initial: true) { _, _ in
                let months = Self.scrubberMonths(spans: model.sectionSpans, side: side)
                scrub.liveMonths = months
                scrub.monthsHeight = months.last.map { $0.startY + $0.height } ?? 0
                updateRowWindow()
            }
            .onChange(of: tailPadding, initial: true) { _, padding in
                scrub.tailPadding = padding
            }
            .onScrollPhaseChange { _, newPhase in
                scrollContext.isIdle = newPhase == .idle
                if newPhase == .idle {
                    updateRowWindow()
                    scheduleIndicatorHide()
                    // the scrubber owns the hold for the length of its drag.
                    if !scrub.isScrubbing { model.resumeRebuilds() }
                } else {
                    AssetViewerOpeningChromeCache.shared.cancelPrewarming(
                        owner: openingChromePrewarmOwner
                    )
                    showIndicator()
                    // reflowing the library under a moving finger is what
                    // makes the grid jump; loads keep landing in the model
                    // and project in one compensated pass at idle.
                    model.deferRebuilds()
                }
            }
            .onChange(of: viewer.isTransitioning) { _, isTransitioning in
                if isTransitioning {
                    AssetViewerOpeningChromeCache.shared.cancelPrewarming(
                        owner: openingChromePrewarmOwner
                    )
                } else {
                    updateRowWindow()
                }
            }
            .onChange(of: isSelecting) { _, isSelecting in
                if isSelecting {
                    AssetViewerOpeningChromeCache.shared.cancelPrewarming(
                        owner: openingChromePrewarmOwner
                    )
                } else {
                    updateRowWindow()
                }
            }
            .onDisappear {
                AssetViewerOpeningChromeCache.shared.cancelPrewarming(
                    owner: openingChromePrewarmOwner
                )
            }
            // the scrollbar is the app's own everywhere, so anything that
            // scrolls at all gets one. gating it on a row count left short
            // albums with no indicator of any kind, the system's being hidden.
            .overlay(alignment: .topTrailing) {
                if scrollable && !viewer.isTransitioning {
                    TimelineScrubber(
                        scrub: scrub,
                        // an absolute jump to the exact pixel, immich-web's
                        // scrollToSegmentPercentage. the virtual stack owns
                        // every row position, so the grid's layout IS the
                        // scroll view's coordinate space and nothing can land
                        // short or clamp - the drag is continuous within a
                        // month, not snapped to it.
                        onScrub: { fraction in
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                scrollPosition.scrollTo(y: scrub.contentOffset(forFraction: fraction))
                            }
                        },
                        onScrubbingChanged: { scrubbing in
                            if scrubbing {
                                AssetViewerOpeningChromeCache.shared.cancelPrewarming(
                                    owner: openingChromePrewarmOwner
                                )
                                showIndicator()
                                model.deferRebuilds()
                            } else {
                                scheduleIndicatorHide()
                                // a drag can end mid-deceleration; the phase
                                // handler lifts the hold once the scroll is
                                // actually at rest.
                                if scrollContext.isIdle { model.resumeRebuilds() }
                                // the window went unwarmed for the length of
                                // the drag; catch it up where it landed.
                                prefetcher.update(
                                    visibleRowIDs: scrollContext.visibleRowIDs,
                                    model: model,
                                    client: session.client,
                                    backup: session.backup,
                                    targetPixelSize: thumbnailPixelSize(for: side)
                                )
                            }
                            // outside the animation below: this swaps what every
                            // tile is made of, and a cross-fade of the whole
                            // grid is not what the thumb thickening asked for.
                            var plain = Transaction()
                            plain.disablesAnimations = true
                            withTransaction(plain) { isScrubbingTiles = scrubbing }
                            let apply = { scrubbing ? scrub.beginScrub() : scrub.endScrub() }
                            if reduceMotion {
                                apply()
                            } else {
                                withAnimation(.easeOut(duration: 0.15)) { apply() }
                            }
                            if !scrubbing { updateRowWindow() }
                        }
                    )
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(showsLargeTitle ? .large : .inline)
        // one toolbar owns the whole trailing group, so selection swaps the
        // items in place - the bar itself stays put and the controls fade
        // where they are instead of sliding away with it. only the tab bar
        // leaves, for the bottom controls, like the photos app.
        .toolbar {
            if isSelecting, !isPicking {
                if filter.isTrashed != true {
                    ToolbarItem(placement: .topBarTrailing) {
                        SelectionMoreMenu(
                            filter: filter,
                            isDisabled: isSelectionWorking || selection.isEmpty,
                            serverActionsDisabled: selectionHasLocalAssets,
                            onFavorite: { await applyFavorite() },
                            onArchive: { await applyVisibility(filter.visibility == .archive ? .timeline : .archive) },
                            onRemoveFromAlbum: filter.albumId != nil ? { await applyRemoveFromAlbum() } : nil,
                            onAddToAlbum: { pendingAlbumAssets = Array(selection) },
                            onBackUp: selectionHasLocalAssets ? applyBackup : nil,
                            backUpTitle: isBackupOnlySelection ? "Back Up" : "Back Up Missing"
                        )
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        exitSelection()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .disabled(isSelectionWorking)
                    .accessibilityLabel("Cancel Selection")
                    .accessibilityIdentifier("selection-cancel")
                }
            } else {
                if !isPicking, !model.isEmpty {
                    // leads the host's items as a pill of its own: the fixed
                    // spacer splits the glass so it never merges into their
                    // group.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Select") { enterSelection() }
                            .accessibilityIdentifier("timeline-select")
                    }
                    if hasTrailingItems {
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    }
                }
                trailingItems
            }
        }
        .toolbarVisibility(isSelecting ? .hidden : .automatic, for: .tabBar)
        .navigationBarBackButtonHidden(isSelecting)
        .overlay { overlayState }
        .overlay(alignment: .bottom) {
            ZStack {
                if isSelecting, !isPicking {
                    SelectionControlBar(
                        count: selection.count,
                        filter: filter,
                        isWorking: isSelectionWorking,
                        onShare: shareSelection,
                        onShowSelected: presentSelectedSheet,
                        onRestore: filter.isTrashed == true ? { await applyRestore() } : nil,
                        onTrash: { await applyTrash() }
                    )
                    .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.25), value: isSelecting)
        }
        .sheet(isPresented: $showsSelectedSheet) {
            SelectedAssetsSheet(assets: selectedSheetAssets, selection: $selection)
        }
        // no pull-to-refresh: the realtime hub keeps every grid current.
        .task {
            if let client = session.client {
                model.attach(client, backup: session.backup, hub: session.realtime)
                model.columns = columnCount
                // capture list only - a self capture would cycle through the
                // @state storage that owns the model and leak it on pop. the
                // weak capture is renamed so it does not shadow the strong
                // reference this task already holds.
                model.applyRowsUpdate = { [weak weakModel = model, context = scrollContext, position = _scrollPosition] old, new, animated, apply in
                    Self.applyRowsChange(
                        old: old, new: new, animated: animated, apply: apply,
                        model: weakModel, context: context, position: position
                    )
                }
                await model.load()
                await revealPendingTimelineTarget()
            }
        }
        .onChange(of: navigationTarget) {
            Task { await revealPendingTimelineTarget() }
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
        .onDisappear {
            prefetcher.cancel()
            model.resumeRebuilds()
        }
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
        .background {
            AssetSharePresenter(request: $shareRequest) {
                exitSelection()
            }
        }
        // escape leaves selection mode from a hardware keyboard. installed
        // for the mode only, so the grid never holds the keyboard otherwise.
        .background {
            if isSelecting, !isPicking {
                KeyCommandHost(
                    isActive: true,
                    commands: [
                        KeyCommandBinding(title: "Cancel Selection", input: UIKeyCommand.inputEscape) {
                            exitSelection()
                        },
                    ]
                )
            }
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

    private func revealPendingTimelineTarget() async {
        guard let target = navigationTarget,
              mergesLocalPhotos,
              scrollContext.viewportWidth > 0
        else { return }
        if let bucketID = model.bucketID(containing: target.localDate) {
            await model.loadBucket(bucketID)
        }
        guard navigationTarget == target,
              let rowIndex = model.rowIndex(containingAnyOf: target.candidateAssetIDs)
        else { return }

        let side = tileSide(for: scrollContext.viewportWidth)
        let layout = rowLayout(side: side)
        guard layout.starts.indices.contains(rowIndex), model.rows.indices.contains(rowIndex) else { return }
        let rowHeight = model.rows[rowIndex].height(tileSide: side)
        let centeringInset = max(0, (scrollContext.viewportHeight - rowHeight) / 2)
        let offset = max(0, scrub.headerHeight + layout.starts[rowIndex] - centeringInset)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollPosition.scrollTo(y: offset)
        }
        navigationTarget = nil
    }

    /// lands a rows swap the way the official clients do: content that
    /// changed above the viewport applies instantly with the scroll offset
    /// shifted by the exact height delta, so visible photos never move;
    /// changes in or below the viewport reflow with an animation when one
    /// was requested.
    private static func applyRowsChange(
        old: [TimelineRow],
        new: [TimelineRow],
        animated: Bool,
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
                    // 0 is the rest position in this space, and the floor.
                    let offset = max(0, context.offsetY + newStart - oldStart)
                    position.wrappedValue.scrollTo(y: offset)
                    // the geometry callback reports the same value a frame
                    // later; the re-window that follows the swap reads it now.
                    context.offsetY = offset
                }
                return
            }
        }
        if !animated || UIAccessibility.isReduceMotionEnabled || !context.isIdle {
            apply()
        } else {
            withAnimation(.smooth(duration: 0.3)) { apply() }
        }
    }

    @ViewBuilder private func rowView(
        _ row: TimelineRow,
        rowIndex: Int,
        side: CGFloat
    ) -> some View {
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
            let targetPixelSize = thumbnailPixelSize(for: side)
            ZStack(alignment: .topLeading) {
                ForEach(runs, id: \.colStart) { run in
                    HStack(spacing: 2) {
                        ForEach(Array(run.assets.enumerated()), id: \.element.id) { offset, asset in
                            let isProjectedRemoved = model.projectedRemovalIDs.contains(asset.id)
                            tile(
                                asset,
                                targetPixelSize: targetPixelSize,
                                selectionPosition: SelectionGridPosition(
                                    row: rowIndex,
                                    column: run.colStart + offset
                                )
                            )
                                .frame(width: side, height: side)
                                .opacity(isProjectedRemoved ? 0 : 1)
                                .allowsHitTesting(!isProjectedRemoved)
                                // plain crossfade: an uploaded photo swaps its
                                // local tile for the server twin with identical
                                // pixels, and any scale effect would read as a
                                // pulse.
                                .transition(.opacity)
                                .animation(
                                    reduceMotion ? nil : .easeOut(duration: 0.12),
                                    value: isProjectedRemoved
                                )
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
        // a day can hold hundreds of ids and this walks the model once per id,
        // so it stays behind the mode that is the only reason to know them.
        let selectableIDs = isSelecting ? segment.selectableIDs.filter(isSelectableAssetID) : []
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

    @ViewBuilder private func tile(
        _ asset: Asset,
        targetPixelSize: CGFloat,
        selectionPosition: SelectionGridPosition
    ) -> some View {
        // picking wants one photo and nothing else, so a tile carries neither
        // the long-press menu nor a viewer of its own while the mode is on.
        if let onPickAsset {
            AssetTile(
                asset: asset,
                showsBackupBadge: mergesLocalPhotos,
                targetPixelSize: targetPixelSize
            )
                .onTapGesture { onPickAsset(asset) }
        } else if isScrubbingTiles {
            // a scrub relands the grid somewhere else every frame, and a tile
            // that carries its own uikit host, context menu and recognizer is
            // far too heavy to build at that rate. nothing can be tapped
            // mid-drag anyway, so the plain tile - identical pixels, drawn
            // inside the grid's own renderer - stands in until the finger
            // lifts. images come straight from the memory cache, so the swap
            // costs no frame.
            AssetTile(
                asset: asset,
                showsBackupBadge: mergesLocalPhotos,
                targetPixelSize: targetPixelSize
            )
        } else {
            InteractiveAssetTile(
                asset: asset,
                showsBackupBadge: mergesLocalPhotos,
                targetPixelSize: targetPixelSize,
                isSelecting: isSelecting,
                isSelected: selection.contains(asset.id),
                isSelectable: isSelectable(asset),
                selectionPosition: selectionPosition,
                registry: tileRegistry,
                toggleSelection: { toggle(asset) },
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

        var transfer: [UIMenuElement] = []
        transfer.append(UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { _ in
            shareRequest = AssetShareRequest(assets: [asset])
        })
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

    /// device photos join selection only while they still need a backup, so
    /// server actions keep their remote-id contract for everything else.
    private func isSelectable(_ asset: Asset) -> Bool {
        if asset.isLocal { return !asset.isLocalBackedUp }
        return owns(asset)
    }

    private func isSelectableAssetID(_ id: String) -> Bool {
        guard let index = model.flatAssetIndex(for: id) else { return false }
        return isSelectable(model.flatAssets[index])
    }

    /// device ids carry the local- prefix, so selection composition reads
    /// off the id set without walking the model.
    private var selectionHasLocalAssets: Bool {
        selection.contains { $0.hasPrefix("local-") }
    }

    /// backed-up device photos are never selectable, so a local-only
    /// selection is exactly the not-yet-backed-up one bulk backup serves.
    private var isBackupOnlySelection: Bool {
        !selection.isEmpty && selection.allSatisfy { $0.hasPrefix("local-") }
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
                if pinchBaseColumns == nil {
                    AssetViewerOpeningChromeCache.shared.cancelPrewarming(
                        owner: openingChromePrewarmOwner
                    )
                }
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
            .onEnded { _ in
                pinchBaseColumns = nil
                updateRowWindow()
            }
    }

    // MARK: - selection

    /// deselecting the last item keeps the mode on - the pill just reads
    /// "Select Items" again, exactly like photos.app.
    private func toggle(_ asset: Asset) {
        if selection.contains(asset.id) {
            selection.remove(asset.id)
        } else {
            selection.insert(asset.id)
        }
    }

    private func selectableAssetIDs(
        in rectangle: SelectionGridRectangle
    ) -> Set<String> {
        guard !model.rows.isEmpty else { return [] }
        let lowerRow = max(0, rectangle.rows.lowerBound)
        let upperRow = min(model.rows.count - 1, rectangle.rows.upperBound)
        guard lowerRow <= upperRow else { return [] }

        var result = Set<String>()
        for rowIndex in lowerRow...upperRow {
            guard case .tiles(_, let runs) = model.rows[rowIndex] else { continue }
            for run in runs {
                for (offset, asset) in run.assets.enumerated() {
                    let column = run.colStart + offset
                    guard rectangle.columns.contains(column),
                          isSelectable(asset),
                          !model.projectedRemovalIDs.contains(asset.id)
                    else { continue }
                    result.insert(asset.id)
                }
            }
        }
        return result
    }

    private func applySelectionRectangle(
        _ changes: [SelectionRectangleState.Change]
    ) {
        guard isSelecting, !changes.isEmpty else { return }
        var updated = selection
        for change in changes where isSelectableAssetID(change.assetID) {
            if change.selects {
                updated.insert(change.assetID)
            } else {
                updated.remove(change.assetID)
            }
        }
        selection = updated
    }

    private func handleSelectionSlideActivity(_ isActive: Bool) {
        if isActive {
            AssetViewerOpeningChromeCache.shared.cancelPrewarming(
                owner: openingChromePrewarmOwner
            )
            showIndicator()
            model.deferRebuilds()
            return
        }
        scheduleIndicatorHide()
        model.resumeRebuilds()
        updateRowWindow()
    }

    /// entry and exit run inside one animation so the toolbar swap, the tab
    /// bar fade and the bottom controls fade move together.
    private func enterSelection() {
        withAnimation(.smooth(duration: 0.25)) {
            isSelecting = true
        }
    }

    private func exitSelection() {
        showsSelectedSheet = false
        withAnimation(.smooth(duration: 0.25)) {
            isSelecting = false
            selection.removeAll()
        }
        selectedSheetAssets.removeAll()
    }

    private var isSelectionWorking: Bool {
        isRunningServerCommand || !selection.isDisjoint(with: mutatingAssetIDs)
    }

    /// the asset list is captured here so deselecting immediately afterwards
    /// cannot change what was asked for; metadata options come from the saved
    /// defaults. selection clears on tap so the grid is free while the share
    /// prepares in the background.
    private func shareSelection() {
        let assets = model.flatAssets.filter { selection.contains($0.id) }
        guard !assets.isEmpty else { return }
        shareRequest = AssetShareRequest(assets: assets, options: .current)
        exitSelection()
    }

    private func presentSelectedSheet() {
        selectedSheetAssets = model.flatAssets.filter { selection.contains($0.id) }
        showsSelectedSheet = true
    }

    private func viewerController(
        for asset: Asset,
        startsAsContextPreview: Bool,
        previewBounds: CGSize
    ) -> AssetViewerHostingController? {
        guard let index = model.flatAssetIndex(for: asset.id) else { return nil }
        guard let route = viewer.makeRoute(
            assets: model.flatAssets,
            initialIndex: index,
            indexByAssetID: model.viewerAssetIndexByID
        ) else { return nil }

        return AssetViewerHostingController(
            route: route,
            startsAsContextPreview: startsAsContextPreview,
            previewBounds: previewBounds,
            session: session,
            sourceRegistry: tileRegistry,
            openingChromePresentation: startsAsContextPreview
                ? nil
                : AssetViewerOpeningChromePresentation(asset: asset, session: session),
            album: filter.albumId.map { AlbumContext(id: $0, ownerID: albumOwnerID) },
            personID: filter.personId,
            willPresent: { route in beginViewerPresentation(route) },
            didPresent: { id in finishViewerOpening(id) },
            didDismiss: { id in finishViewer(id) },
            onChange: { change in handleViewerChange(change) }
        )
    }

    private func beginViewerPresentation(_ route: ViewerRoute) -> Bool {
        viewer.activate(
            route,
            presentsCover: false,
            replacesSettlingPresentation: true
        )
    }

    private func finishViewerOpening(_ id: UUID) {
        guard viewer.isActive(id) else { return }
        model.suspendForViewer()
        hideScrubberForViewer()
    }

    private func finishViewer(_ id: UUID) {
        viewer.complete(id)
        guard !viewer.isTransitioning else { return }
        model.resumeAfterViewer()
    }

    private func hideScrubberForViewer() {
        indicatorHideTask?.cancel()
        indicatorHideTask = nil
        // a drag interrupted by the viewer never reaches its onEnded, so the
        // hold it took out is released here rather than left standing.
        if isScrubbingTiles { isScrubbingTiles = false }
        model.resumeRebuilds()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if scrub.isScrubbing { scrub.endScrub() }
            if scrub.indicatorVisible { scrub.indicatorVisible = false }
            if scrub.indicatorGrabbable { scrub.indicatorGrabbable = false }
        }
    }

    private func showIndicator() {
        guard !viewer.isTransitioning else { return }
        indicatorHideTask?.cancel()
        indicatorHideTask = nil
        // a phase change fires three times a fling and @observable notifies on
        // every write, equal or not, so each one is worth a look first.
        if !scrub.indicatorGrabbable { scrub.indicatorGrabbable = true }
        guard !scrub.indicatorVisible else { return }
        if reduceMotion {
            scrub.indicatorVisible = true
        } else {
            withAnimation(.easeOut(duration: 0.12)) { scrub.indicatorVisible = true }
        }
    }

    private func scheduleIndicatorHide() {
        guard !viewer.isTransitioning else { return }
        indicatorHideTask?.cancel()
        indicatorHideTask = Task {
            try? await Task.sleep(for: .milliseconds(1_100))
            guard !Task.isCancelled, !scrub.isScrubbing else { return }
            if reduceMotion {
                scrub.indicatorVisible = false
            } else {
                withAnimation(.easeOut(duration: 0.25)) { scrub.indicatorVisible = false }
            }
            // grace window: the thumb is gone but still catchable, so reaching
            // for it right after it fades does not scroll the grid instead.
            try? await Task.sleep(for: .milliseconds(2_500))
            guard !Task.isCancelled, !scrub.isScrubbing else { return }
            scrub.indicatorGrabbable = false
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
    /// its half of the operation. not-yet-backed-up device photos have no
    /// server half at all: deleting them only removes them from the library.
    @discardableResult
    private func deleteAssets(_ assets: [Asset], force: Bool) async -> Bool {
        guard let client = session.client else {
            ErrorToastCenter.shared.show("The server is not available.")
            return false
        }
        let targets = assets.compactMap { asset -> (sourceID: String, serverID: String)? in
            serverIdentifier(for: asset).map { (asset.id, $0) }
        }
        let serverSourceIDs = Set(targets.map(\.sourceID))
        let deviceOnlyIDs = Set(assets.map(\.id)).subtracting(serverSourceIDs)
        let sourceIDs = serverSourceIDs.union(deviceOnlyIDs)
        guard !sourceIDs.isEmpty, beginServerMutation(ids: sourceIDs) else { return false }
        defer { finishServerMutation(ids: sourceIDs) }

        var localIDs = Set<String>()
        for asset in assets {
            if let localID = pairedLocalIdentifier(for: asset) {
                localIDs.insert(localID)
            } else if let serverID = serverIdentifier(for: asset),
                      let backup = session.backup,
                      let localID = await backup.localIdentifier(forRemote: serverID) {
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

        // the device copies are gone for good at this point, so device-only
        // photos leave the grid immediately and never roll back.
        if !deviceOnlyIDs.isEmpty {
            model.commit(model.removeAssetsForOptimisticAction(ids: deviceOnlyIDs))
        }
        guard !targets.isEmpty else { return true }

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
            apply: { removal = model.removeAssetsForOptimisticAction(ids: serverSourceIDs) },
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

    /// uploads continue after the mode closes so tiles report progress
    /// through their own overlays, like the single-asset menu action.
    private func applyBackup() {
        guard let backup = session.backup else {
            ErrorToastCenter.shared.show("Backup is not available.")
            return
        }
        let localIDs = model.flatAssets
            .filter { selection.contains($0.id) }
            .compactMap(\.localIdentifier)
        guard !localIDs.isEmpty else { return }
        exitSelection()
        Task {
            do {
                let outcome = try await backup.backUp(localIdentifiers: localIDs)
                if outcome.failed > 0 {
                    ErrorToastCenter.shared.show(bulkBackupFailureMessage(outcome))
                }
            } catch {
                ErrorToastCenter.shared.show("Couldn’t back up", error: error)
            }
            // partial uploads may have landed even when the run threw.
            await model.refreshLocalItems()
        }
    }

    private func bulkBackupFailureMessage(_ outcome: BulkBackupOutcome) -> String {
        let base = outcome.failed == 1
            ? "Couldn’t back up 1 item."
            : "Couldn’t back up \(outcome.failed) items."
        guard let reason = outcome.firstFailure else { return base }
        return "\(base) \(reason)"
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
                height: height
            )
        }
    }
}

/// every input to the month layout, in o(1): the two row tallies move whenever
/// any month's height does, and the ends catch a month appearing or leaving.
/// the layout version catches a rows swap that leaves every tally as it was -
/// a placeholder replaced by exactly the rows it estimated - which still has
/// to re-window, since the mounted range was sized for the old rows. without
/// it a one-month album mounted nothing but its day title until the first
/// scroll.
private struct ScrubberLayoutKey: Equatable {
    let layoutVersion: Int
    let titleBands: Int
    let tileRows: Int
    let count: Int
    let first: String?
    let last: String?
    let side: CGFloat

    init(model: TimelineModel, side: CGFloat) {
        layoutVersion = model.rowsLayoutVersion
        titleBands = model.titleBandCount
        tileRows = model.tileRowCount
        count = model.sectionSpans.count
        first = model.sectionSpans.first?.id
        last = model.sectionSpans.last?.id
        self.side = side
    }
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

@MainActor
private protocol SelectionAutoScrollerDelegate: AnyObject {
    func selectionAutoScrollerDidScroll(to point: CGPoint, in window: UIWindow)
}

@MainActor
private final class SelectionAutoScroller {
    @MainActor
    private final class DisplayLinkTarget: NSObject {
        weak var owner: SelectionAutoScroller?

        @objc func tick(_ displayLink: CADisplayLink) {
            owner?.advance(displayLink)
        }
    }

    weak var delegate: SelectionAutoScrollerDelegate?
    private weak var scrollView: UIScrollView?
    private weak var window: UIWindow?
    private var location = CGPoint.zero
    private var speed: CGFloat = 0
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private let displayLinkTarget = DisplayLinkTarget()

    init(delegate: SelectionAutoScrollerDelegate) {
        self.delegate = delegate
        displayLinkTarget.owner = self
    }

    deinit {
        displayLink?.invalidate()
    }

    func update(location: CGPoint, in window: UIWindow, scrollView: UIScrollView) {
        self.location = location
        self.window = window
        self.scrollView = scrollView
        let frame = scrollView.convert(scrollView.bounds, to: window)
        guard frame.height > 0 else {
            stopDisplayLink()
            return
        }
        speed = SelectionAutoScrollProfile.timeline.speed(
            at: location.y,
            in: frame.minY...frame.maxY
        )
        if speed == 0 {
            stopDisplayLink()
        } else {
            startDisplayLink()
        }
    }

    func stop() {
        speed = 0
        scrollView = nil
        window = nil
        stopDisplayLink()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(
            target: displayLinkTarget,
            selector: #selector(DisplayLinkTarget.tick(_:))
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    private func advance(_ displayLink: CADisplayLink) {
        guard let scrollView, let window, speed != 0 else {
            stop()
            return
        }
        let elapsed = lastTimestamp.map { displayLink.timestamp - $0 }
            ?? displayLink.targetTimestamp - displayLink.timestamp
        lastTimestamp = displayLink.timestamp
        let interval = min(1.0 / 15.0, max(0, elapsed))
        let insets = scrollView.adjustedContentInset
        let minimumY = -insets.top
        let maximumY = max(
            minimumY,
            scrollView.contentSize.height - scrollView.bounds.height + insets.bottom
        )
        let currentY = scrollView.contentOffset.y
        let targetY = min(maximumY, max(minimumY, currentY + speed * interval))
        guard abs(targetY - currentY) > 0.01 else { return }
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: targetY),
            animated: false
        )
        delegate?.selectionAutoScrollerDidScroll(to: location, in: window)
    }
}

@MainActor
private final class TimelineSelectionSlideController: NSObject,
    UIGestureRecognizerDelegate,
    SelectionAutoScrollerDelegate
{
    private weak var scrollView: UIScrollView?
    private weak var directRecognizer: UIPanGestureRecognizer?
    private weak var heldRecognizer: UILongPressGestureRecognizer?
    private weak var activeRecognizer: UIGestureRecognizer?
    private var isEnabled = false
    private var isActive = false
    private var selectedIDs = Set<String>()
    private var origin: SelectionGridPosition?
    private var target: SelectionGridPosition?
    private var selectionRectangle = SelectionRectangleState()
    private var assetIDsInRectangle: (SelectionGridRectangle) -> Set<String> = { _ in [] }
    private var applyChanges: ([SelectionRectangleState.Change]) -> Void = { _ in }
    private var onActiveChanged: (Bool) -> Void = { _ in }
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private lazy var autoScroller = SelectionAutoScroller(delegate: self)

    func configure(
        isEnabled: Bool,
        selectedIDs: Set<String>,
        assetIDsInRectangle: @escaping (SelectionGridRectangle) -> Set<String>,
        applyChanges: @escaping ([SelectionRectangleState.Change]) -> Void,
        onActiveChanged: @escaping (Bool) -> Void
    ) {
        self.selectedIDs = selectedIDs
        self.assetIDsInRectangle = assetIDsInRectangle
        self.applyChanges = applyChanges
        self.onActiveChanged = onActiveChanged
        self.isEnabled = isEnabled
        if !isEnabled { finishSelection() }
        directRecognizer?.isEnabled = isEnabled
        heldRecognizer?.isEnabled = isEnabled
    }

    func attach(to scrollView: UIScrollView) {
        guard self.scrollView !== scrollView else { return }
        detach()
        let direct = UIPanGestureRecognizer(target: self, action: #selector(selected(_:)))
        direct.maximumNumberOfTouches = 1
        direct.delegate = self
        direct.isEnabled = isEnabled
        let held = UILongPressGestureRecognizer(target: self, action: #selector(selected(_:)))
        held.minimumPressDuration = 0.3
        held.allowableMovement = 14
        held.numberOfTouchesRequired = 1
        held.delegate = self
        held.isEnabled = isEnabled
        scrollView.addGestureRecognizer(direct)
        scrollView.addGestureRecognizer(held)
        scrollView.panGestureRecognizer.require(toFail: direct)
        self.scrollView = scrollView
        directRecognizer = direct
        heldRecognizer = held
    }

    func detach() {
        finishSelection()
        if let directRecognizer { scrollView?.removeGestureRecognizer(directRecognizer) }
        if let heldRecognizer { scrollView?.removeGestureRecognizer(heldRecognizer) }
        directRecognizer = nil
        heldRecognizer = nil
        scrollView = nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard isEnabled,
              let scrollView,
              let window = scrollView.window
        else { return false }
        let point = originPoint(of: gestureRecognizer, in: window)
        guard tile(at: point, in: scrollView, window: window)?.isSelectable == true else {
            return false
        }
        guard let direct = gestureRecognizer as? UIPanGestureRecognizer else {
            return gestureRecognizer === heldRecognizer
        }
        guard gestureRecognizer === directRecognizer else { return false }
        let translation = direct.translation(in: window)
        return SelectionDirectDragIntent.timeline.matches(
            translation: CGSize(width: translation.x, height: translation.y)
        )
    }

    @objc private func selected(_ recognizer: UIGestureRecognizer) {
        guard let scrollView, let window = scrollView.window else {
            finishSelection()
            return
        }
        let point = recognizer.location(in: window)
        switch recognizer.state {
        case .began:
            beginSelection(recognizer, point: point, scrollView: scrollView, window: window)
        case .changed:
            guard activeRecognizer === recognizer else { return }
            updateRectangle(at: point, in: scrollView, window: window)
            autoScroller.update(location: point, in: window, scrollView: scrollView)
        case .ended, .cancelled, .failed:
            if activeRecognizer === recognizer { finishSelection() }
        default:
            break
        }
    }

    private func beginSelection(
        _ recognizer: UIGestureRecognizer,
        point: CGPoint,
        scrollView: UIScrollView,
        window: UIWindow
    ) {
        guard activeRecognizer == nil else { return }
        guard let tile = tile(
            at: originPoint(of: recognizer, in: window),
            in: scrollView,
            window: window
        ), tile.isSelectable else { return }
        activeRecognizer = recognizer
        origin = tile.selectionPosition
        target = nil
        selectionRectangle.begin(
            originIsSelected: tile.isSelected,
            selectedIDs: selectedIDs
        )
        setActive(true)
        selectionFeedback.prepare()
        updateRectangle(at: point, in: scrollView, window: window)
        autoScroller.update(location: point, in: window, scrollView: scrollView)
    }

    private func finishSelection() {
        autoScroller.stop()
        selectionRectangle.end()
        activeRecognizer = nil
        origin = nil
        target = nil
        setActive(false)
    }

    private func setActive(_ isActive: Bool) {
        guard self.isActive != isActive else { return }
        self.isActive = isActive
        onActiveChanged(isActive)
    }

    private func originPoint(
        of recognizer: UIGestureRecognizer,
        in window: UIWindow
    ) -> CGPoint {
        let point = recognizer.location(in: window)
        guard let pan = recognizer as? UIPanGestureRecognizer else { return point }
        let translation = pan.translation(in: window)
        return CGPoint(x: point.x - translation.x, y: point.y - translation.y)
    }

    private func updateRectangle(
        at point: CGPoint,
        in scrollView: UIScrollView,
        window: UIWindow
    ) {
        guard let origin,
              let tile = tile(at: point, in: scrollView, window: window),
              tile.selectionPosition != target
        else { return }
        target = tile.selectionPosition
        let rectangle = SelectionGridRectangle(origin: origin, target: tile.selectionPosition)
        apply(selectionRectangle.update(assetIDs: assetIDsInRectangle(rectangle)))
    }

    private func tile(
        at point: CGPoint,
        in scrollView: UIScrollView,
        window: UIWindow
    ) -> InteractiveAssetTileView? {
        let frame = scrollView.convert(scrollView.bounds, to: window)
        guard frame.width > 2, frame.height > 2 else { return nil }
        let clamped = CGPoint(
            x: min(frame.maxX - 1, max(frame.minX + 1, point.x)),
            y: min(frame.maxY - 1, max(frame.minY + 1, point.y))
        )
        var candidate = scrollView.hitTest(scrollView.convert(clamped, from: window), with: nil)
        while let view = candidate {
            if let tile = view as? InteractiveAssetTileView { return tile }
            candidate = view.superview
        }
        return nil
    }

    private func apply(_ changes: [SelectionRectangleState.Change]) {
        guard !changes.isEmpty else { return }
        applyChanges(changes)
        selectionFeedback.selectionChanged()
        selectionFeedback.prepare()
    }

    func selectionAutoScrollerDidScroll(to point: CGPoint, in window: UIWindow) {
        guard let scrollView else { return }
        updateRectangle(at: point, in: scrollView, window: window)
    }
}

private final class TimelineSelectionSlideInstallerView: UIView {
    weak var controller: TimelineSelectionSlideController?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attach()
    }

    func attach() {
        guard window != nil else { return }
        var candidate = superview
        while let view = candidate {
            if let scrollView = view as? UIScrollView {
                controller?.attach(to: scrollView)
                return
            }
            candidate = view.superview
        }
    }
}

private struct TimelineSelectionSlideInstaller: UIViewRepresentable {
    let controller: TimelineSelectionSlideController
    let isEnabled: Bool
    let selectedIDs: Set<String>
    let assetIDsInRectangle: (SelectionGridRectangle) -> Set<String>
    let applyChanges: ([SelectionRectangleState.Change]) -> Void
    let onActiveChanged: (Bool) -> Void

    func makeUIView(context: Context) -> TimelineSelectionSlideInstallerView {
        let view = TimelineSelectionSlideInstallerView()
        view.isUserInteractionEnabled = false
        view.controller = controller
        configureController()
        return view
    }

    func updateUIView(_ uiView: TimelineSelectionSlideInstallerView, context: Context) {
        uiView.controller = controller
        configureController()
        uiView.attach()
    }

    static func dismantleUIView(
        _ uiView: TimelineSelectionSlideInstallerView,
        coordinator: Void
    ) {
        uiView.controller?.detach()
    }

    private func configureController() {
        controller.configure(
            isEnabled: isEnabled,
            selectedIDs: selectedIDs,
            assetIDsInRectangle: assetIDsInRectangle,
            applyChanges: applyChanges,
            onActiveChanged: onActiveChanged
        )
    }
}

/// the uikit-hosted tile owns tap and long press. swiftui context menus cannot
/// commit when the floating preview is tapped, so the interaction stays on the
/// same view that draws the tile.
private final class InteractiveAssetTileView: UIView {
    var isSelected = false
    var isSelectable = false
    var selectionPosition = SelectionGridPosition(row: 0, column: 0)
}

private struct InteractiveAssetTile: UIViewRepresentable {
    @Environment(SessionStore.self) private var session
    let asset: Asset
    let showsBackupBadge: Bool
    let targetPixelSize: CGFloat
    let isSelecting: Bool
    let isSelected: Bool
    let isSelectable: Bool
    let selectionPosition: SelectionGridPosition
    let registry: AssetTileRegistry
    let toggleSelection: () -> Void
    let menu: () -> UIMenu
    let makeViewer: (_ startsAsContextPreview: Bool, _ bounds: CGSize) -> AssetViewerHostingController?

    func makeUIView(context: Context) -> InteractiveAssetTileView {
        let view = InteractiveAssetTileView()
        view.backgroundColor = .clear
        // pointer feedback on ipad, the same highlight photos gives its grid.
        view.hoverStyle = UIHoverStyle(effect: .highlight)
        updateInteractionState(of: view)
        let contentView = configuration.makeContentView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: view.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        context.coordinator.contentView = contentView
        view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.tapped(_:))
        )
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        view.addGestureRecognizer(tap)
        let indicator = UIImageView()
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.contentMode = .scaleAspectFit
        indicator.isUserInteractionEnabled = false
        view.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            indicator.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            indicator.widthAnchor.constraint(equalToConstant: 24),
            indicator.heightAnchor.constraint(equalToConstant: 24),
        ])
        context.coordinator.selectionIndicator = indicator
        context.coordinator.rendered = RenderedTile(
            asset: asset,
            showsBackupBadge: showsBackupBadge,
            targetPixelSize: targetPixelSize
        )
        context.coordinator.register(
            view,
            asset: asset,
            targetPixelSize: targetPixelSize,
            in: registry
        )
        context.coordinator.updateSelectionAppearance()
        return view
    }

    func updateUIView(_ uiView: InteractiveAssetTileView, context: Context) {
        context.coordinator.host = self
        updateInteractionState(of: uiView)
        // every scroll phase change re-runs the grid body, and each tile hosts
        // a swiftui renderer of its own: handing back an identical
        // configuration would redraw all of them for nothing. backup state
        // and the session are observed by the hosted tile itself and redraw
        // without being reconfigured.
        let rendered = RenderedTile(
            asset: asset,
            showsBackupBadge: showsBackupBadge,
            targetPixelSize: targetPixelSize
        )
        if context.coordinator.rendered != rendered {
            context.coordinator.rendered = rendered
            context.coordinator.register(
                uiView,
                asset: asset,
                targetPixelSize: targetPixelSize,
                in: registry
            )
            (context.coordinator.contentView as? UIContentView)?.configuration = configuration
        }
        context.coordinator.updateSelectionAppearance()
    }

    /// everything the hosted tile draws from.
    struct RenderedTile: Equatable {
        let asset: Asset
        let showsBackupBadge: Bool
        let targetPixelSize: CGFloat
    }

    struct SelectionAppearance: Equatable {
        let isSelecting: Bool
        let isSelected: Bool
        let isSelectable: Bool
    }

    static func dismantleUIView(_ uiView: InteractiveAssetTileView, coordinator: Coordinator) {
        coordinator.unregister(uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(host: self, registry: registry)
    }

    /// the hosted root does not inherit this screen's environment, so the
    /// session is re-injected.
    private var configuration: UIHostingConfiguration<some View, some View> {
        UIHostingConfiguration {
            AssetTile(
                asset: asset,
                showsBackupBadge: showsBackupBadge,
                targetPixelSize: targetPixelSize
            )
                .environment(session)
        }
        .margins(.all, 0)
    }

    private func updateInteractionState(of view: InteractiveAssetTileView) {
        view.isSelected = isSelected
        view.isSelectable = isSelectable
        view.selectionPosition = selectionPosition
    }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var host: InteractiveAssetTile
        /// inputs behind the configuration currently installed on the view.
        var rendered: RenderedTile?
        weak var contentView: UIView?
        weak var selectionIndicator: UIImageView?
        private var registry: AssetTileRegistry
        private var registeredAssetID: String?
        private var registeredAsset: Asset?
        private var registeredTargetPixelSize: CGFloat?
        private var selectionAppearance: SelectionAppearance?

        init(host: InteractiveAssetTile, registry: AssetTileRegistry) {
            self.host = host
            self.registry = registry
        }

        func register(
            _ view: UIView,
            asset: Asset,
            targetPixelSize: CGFloat,
            in registry: AssetTileRegistry
        ) {
            if (self.registry !== registry || registeredAssetID != asset.id),
               let registeredAssetID {
                self.registry.unregister(view, for: registeredAssetID)
            }
            guard self.registry !== registry
                    || registeredAssetID != asset.id
                    || registeredAsset != asset
                    || registeredTargetPixelSize != targetPixelSize
            else { return }
            self.registry = registry
            registeredAssetID = asset.id
            registeredAsset = asset
            registeredTargetPixelSize = targetPixelSize
            registry.register(
                view,
                asset: asset,
                session: host.session,
                targetPixelSize: targetPixelSize
            )
        }

        func unregister(_ view: UIView) {
            guard let registeredAssetID else { return }
            registry.unregister(view, for: registeredAssetID)
            self.registeredAssetID = nil
            registeredAsset = nil
            registeredTargetPixelSize = nil
        }

        func updateSelectionAppearance() {
            guard let selectionIndicator else { return }
            selectionIndicator.superview?.bringSubviewToFront(selectionIndicator)
            let appearance = SelectionAppearance(
                isSelecting: host.isSelecting,
                isSelected: host.isSelected,
                isSelectable: host.isSelectable
            )
            guard appearance != selectionAppearance else { return }
            selectionAppearance = appearance
            selectionIndicator.isHidden = !appearance.isSelecting || !appearance.isSelectable
            guard !selectionIndicator.isHidden else { return }
            let name = appearance.isSelected ? "checkmark.circle.fill" : "circle"
            // uikit does not inherit the asset catalog accent, resolve the brand tint directly.
            let secondary = appearance.isSelected
                ? UIColor(resource: .brandTint)
                : UIColor.black.withAlphaComponent(0.25)
            let configuration = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
                .applying(UIImage.SymbolConfiguration(paletteColors: [.white, secondary]))
            selectionIndicator.image = UIImage(
                systemName: name,
                withConfiguration: configuration
            )
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            if host.isSelecting {
                if host.isSelectable { host.toggleSelection() }
                return
            }
            guard let view = recognizer.view,
                  let bounds = view.window?.bounds.size,
                  let presenter = presentationAnchor(for: view)
            else { return }
            let viewer = host.makeViewer(false, bounds)
            guard let viewer else { return }
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
                  let bounds = view.window?.bounds.size,
                  let presenter = presentationAnchor(for: view),
                  let viewer = host.makeViewer(false, bounds)
            else { return }

            // `.pop` owns the visual expansion. its disposable preview is
            // replaced by a prepared full viewer only after uikit releases it.
            viewer.prepareViewerContentForContextCommit()
            animator.preferredCommitStyle = .pop
            animator.addCompletion {
                viewer.presentAfterContextCommit(from: presenter)
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

    private var scrubbedMonth: String? {
        guard scrub.scrollRange > 0 else { return nil }
        return scrub.month(atFraction: scrub.fraction)?.title
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if scrub.isScrubbing {
                    ScrubberMarkerRail(marks: scrub.railMarks())
                        .equatable()
                        .transition(.opacity)
                    if let month = scrubbedMonth {
                        // drawn after the rail in the overlay zstack, so it
                        // passes over the markers while hugging the indicator.
                        ScrubberMonthLabel(title: month)
                            .equatable()
                            .padding(.trailing, 10)
                            .offset(y: scrub.thumbCenterY - 17)
                            .transition(.opacity)
                            .accessibilityIdentifier("timeline-scrubber-label")
                            .onChange(of: month) {
                                UISelectionFeedbackGenerator().selectionChanged()
                            }
                    }
                }

                if scrub.indicatorVisible || scrub.isScrubbing {
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
                .allowsHitTesting(scrub.indicatorGrabbable || scrub.isScrubbing)
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

/// one rail entry: a year chip, a month dot, or both.
private struct ScrubberRailMark: Identifiable, Equatable {
    let id: String
    let y: CGFloat
    let year: String?
    let hasDot: Bool
}

/// year labels at year boundaries and dots for months, spaced with the
/// minimum-distance rules immich-web uses and placed with the same mapping
/// the indicator thumb sweeps.
///
/// equatable, and given already-computed marks: the thumb it hangs beside
/// re-renders on every frame of a drag, and rebuilding a rail of glass chips
/// alongside it is what made a scrub crawl on a large library.
private struct ScrubberMarkerRail: View, Equatable {
    let marks: [ScrubberRailMark]

    var body: some View {
        GlassEffectContainer {
            ZStack(alignment: .topTrailing) {
                ForEach(marks) { mark in
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
                            .fill(Color(.label))
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
}

/// floating month pill riding the indicator thumb, naming whatever month
/// sits at the viewport top. equatable on its title alone: it rides along on
/// every frame of a drag but only ever reads differently at a month boundary,
/// and re-blurring glass sixty times a second for the same word is not free.
private struct ScrubberMonthLabel: View, Equatable {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
            .frame(height: 34)
    }
}
