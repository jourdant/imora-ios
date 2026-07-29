import SwiftUI

nonisolated struct ViewerContext: Identifiable {
    let assets: [Asset]
    let index: Int
    var id: String { assets[index].id }
}

/// reusable bucketed photo grid, the workhorse behind most screens.
struct TimelineScreen<Header: View>: View {
    @Environment(SessionStore.self) private var session

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
    @State private var scrubLabel: String?
    @State private var pendingAlbumAssets: [String]?
    @State private var columnCount = 3
    @State private var pinchBaseColumns: Int?

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount)
    }

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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12, pinnedViews: []) {
                    header

                    ForEach(model.sections) { section in
                        sectionView(section)
                            .id(section.id)
                    }
                }
                .padding(.bottom, isSelecting ? 90 : 0)
            }
            .scrollIndicators(.hidden)
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let base = pinchBaseColumns ?? columnCount
                        pinchBaseColumns = base
                        // zooming in shows fewer, larger tiles.
                        let target = min(5, max(2, Int((Double(base) / value.magnification).rounded())))
                        if target != columnCount {
                            let generator = UISelectionFeedbackGenerator()
                            generator.selectionChanged()
                            withAnimation(.smooth(duration: 0.25)) { columnCount = target }
                        }
                    }
                    .onEnded { _ in pinchBaseColumns = nil }
            )
            .onScrollPhaseChange { _, newPhase in
                if newPhase != .idle {
                    showScrubber()
                }
            }
            .overlay(alignment: .trailing) {
                if model.sections.count > 4 {
                    TimelineScrubber(
                        sections: model.sections,
                        visible: scrubberVisible || isScrubbing,
                        isScrubbing: $isScrubbing,
                        label: $scrubLabel
                    ) { sectionID in
                        proxy.scrollTo(sectionID, anchor: .top)
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
        .overlay {
            overlayState
        }
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
                await model.load()
            }
        }
        .fullScreenCover(item: $viewer) { context in
            AssetViewerScreen(assets: context.assets, initialIndex: context.index) { change in
                handleViewerChange(change)
            }
        }
        .sheet(item: $pendingAlbumAssets) { ids in
            AlbumPickerSheet(assetIDs: ids) {
                exitSelection()
            }
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

    // MARK: - sections

    @ViewBuilder private func sectionView(_ section: TimelineSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.monthTitle)
                .font(.title2.weight(.bold))
                .padding(.horizontal, 16)
                .padding(.top, 12)

            if let days = section.days {
                ForEach(days) { day in
                    dayView(day)
                }
            } else {
                bucketPlaceholder(count: section.count)
                    .onAppear { Task { await model.loadBucket(section.id) } }
            }
        }
    }

    @ViewBuilder private func dayView(_ day: DayGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(day.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if isSelecting {
                    let allSelected = day.assets.allSatisfy { selection.contains($0.id) }
                    Button {
                        toggleDay(day, select: !allSelected)
                    } label: {
                        Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(allSelected ? Color.accentColor : .secondary)
                    }
                }
            }
            .padding(.horizontal, 16)

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(day.assets) { asset in
                    tile(asset)
                }
            }
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

    @ViewBuilder private func bucketPlaceholder(count: Int) -> some View {
        let rows = max(1, Int((Double(count) / Double(columnCount)).rounded(.up)))
        let side = (UIScreen.main.bounds.width - CGFloat(columnCount - 1) * 2) / CGFloat(columnCount)
        VStack(spacing: 2) {
            ForEach(0..<min(rows, 40), id: \.self) { _ in
                HStack(spacing: 2) {
                    ForEach(0..<columnCount, id: \.self) { _ in
                        Rectangle()
                            .fill(Color(.secondarySystemFill))
                            .frame(height: side)
                    }
                }
            }
        }
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

    private func toggleDay(_ day: DayGroup, select: Bool) {
        if select {
            selection.formUnion(day.assets.map(\.id))
        } else {
            selection.subtract(day.assets.map(\.id))
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
        try? await client.trashAssets(ids: Array(selection))
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
        scrubberVisible = true
        scrubberHideTask?.cancel()
        scrubberHideTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { scrubberVisible = false }
        }
    }
}

extension [String]: @retroactive Identifiable {
    public var id: String { joined(separator: ",") }
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

/// right-edge drag scrubber with a floating month label.
private struct TimelineScrubber: View {
    let sections: [TimelineSection]
    let visible: Bool
    @Binding var isScrubbing: Bool
    @Binding var label: String?
    let onJump: (String) -> Void

    @State private var fraction: CGFloat = 0
    @State private var lastSectionID: String?

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height - 120
            ZStack(alignment: .topTrailing) {
                Color.clear

                HStack(spacing: 10) {
                    if isScrubbing, let label {
                        Text(label)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .glassEffect(.regular, in: .capsule)
                            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
                    }

                    Capsule()
                        .fill(.clear)
                        .frame(width: 36, height: 44)
                        .glassEffect(.regular, in: .capsule)
                        .overlay {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                }
                .offset(y: 60 + fraction * height - 22)
                .opacity(visible ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: visible)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard visible || isScrubbing else { return }
                        isScrubbing = true
                        fraction = min(1, max(0, (value.location.y - 60) / height))
                        scrub(to: fraction)
                    }
                    .onEnded { _ in
                        isScrubbing = false
                        label = nil
                    },
                including: .gesture
            )
            .allowsHitTesting(visible || isScrubbing)
        }
        .frame(width: 52)
    }

    private func scrub(to fraction: CGFloat) {
        let total = sections.reduce(0) { $0 + $1.count }
        guard total > 0 else { return }
        let target = Int(fraction * CGFloat(total))
        var running = 0
        for section in sections {
            running += section.count
            if running >= target {
                label = section.monthTitle
                if section.id != lastSectionID {
                    lastSectionID = section.id
                    let generator = UISelectionFeedbackGenerator()
                    generator.selectionChanged()
                    onJump(section.id)
                }
                return
            }
        }
    }
}
