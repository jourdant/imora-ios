import CoreLocation
import MapKit
import SwiftUI

/// full screen apple map of every geotagged asset. the official clients render
/// maplibre tiles from the server's style url; here mapkit supplies the map and
/// only the markers come from immich.
struct MapScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.openURL) private var openURL

    /// frames the map on one spot instead of the whole library, e.g. when the
    /// map is opened from a place.
    var initialCoordinate: CLLocationCoordinate2D?

    @State private var model = MapModel()
    @State private var settings = MapSettings.load()
    @State private var camera: MapCameraPosition = .automatic
    @State private var viewportWidth: CGFloat = 0
    @State private var didFrameMarkers = false
    @State private var showSettings = false
    @State private var area: MapAreaLink?
    @State private var viewer = ViewerPresentation()
    @State private var openingAssetID: String?
    @State private var locator = MapLocator()
    @Namespace private var zoomNamespace

    var body: some View {
        @Bindable var viewer = viewer
        @Bindable var locator = locator

        // the map bleeds past the safe area, the chrome stays inside it so the
        // pill never hides behind the floating tab bar.
        ZStack(alignment: .bottom) {
            Map(position: $camera) {
                ForEach(model.visibleClusters) { cluster in
                    Annotation(cluster.placeName ?? "", coordinate: cluster.coordinate) {
                        MapAssetMarker(
                            cluster: cluster,
                            isOpening: openingAssetID == cluster.representative.id,
                            // markers carry no thumbhash, so there is no cache
                            // buster to pass here.
                            thumbnailURL: session.client?.thumbnailURL(assetID: cluster.representative.id)
                        ) {
                            select(cluster)
                        }
                        .matchedTransitionSource(id: cluster.representative.id, in: zoomNamespace)
                    }
                }
                .annotationTitles(.hidden)

                UserAnnotation()
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                viewportWidth = width
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                model.cameraChanged(region: context.region, viewportWidth: viewportWidth)
            }
            .ignoresSafeArea(edges: .bottom)
            .overlay { statusOverlay }

            // chrome layer, laid out inside the safe area.
            ZStack(alignment: .bottom) {
                browseBar
                HStack {
                    Spacer()
                    locationButton
                }
            }
            .padding(.bottom, 16)
        }
        .navigationTitle("Map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                .accessibilityIdentifier("map-settings")
            }
        }
        .sheet(isPresented: $showSettings) {
            MapSettingsSheet(settings: $settings)
        }
        .navigationDestination(item: $area) { area in
            TimelineScreen(
                title: area.title,
                filter: settings.timelineFilter(bbox: area.bounds),
                emptyIcon: "mappin.slash",
                emptyMessage: "No photos here",
                showsLargeTitle: false
            )
        }
        .task(id: settings) {
            guard let client = session.client else { return }
            await model.load(client: client, options: settings.markerOptions)
            await frameMarkersIfNeeded()
        }
        .onChange(of: settings) { _, updated in
            updated.save()
        }
        .onChange(of: locator.fix) { _, fix in
            guard let fix else { return }
            locator.fix = nil
            withAnimation(.easeInOut(duration: 0.35)) {
                camera = .region(MKCoordinateRegion(
                    center: fix.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15)
                ))
            }
        }
        .alert("Location is off", isPresented: $locator.isDenied) {
            Button("Open Settings") {
                if let url = URL(string: "app-settings:") { openURL(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow location access to see where you are on the map.")
        }
        .fullScreenCover(item: $viewer.route) { route in
            AssetViewerScreen(
                assets: route.assets,
                initialIndex: route.initialIndex,
                presentationID: route.id,
                zoomNamespace: zoomNamespace,
                onDismissed: { viewer.complete(route.id) }
            ) { _ in
                MapMarkerCache.shared.invalidate()
            }
        }
    }

    // MARK: - chrome

    @ViewBuilder private var browseBar: some View {
        if model.visibleCount > 0, let bounds = model.visibleBounds {
            Button {
                area = MapAreaLink(title: "\(model.visibleCount) Photos", bounds: bounds)
            } label: {
                Label("Browse \(model.visibleCount) Photos", systemImage: "square.grid.2x2")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("map-browse")
            .transition(.opacity)
        }
    }

    /// asks for the location permission only when pressed, the way the official
    /// clients do, then drops the camera on the fix.
    private var locationButton: some View {
        Button {
            locator.locate()
        } label: {
            Group {
                if locator.isLocating {
                    ProgressView()
                } else {
                    Image(systemName: "location")
                        .font(.body.weight(.semibold))
                }
            }
            .frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 16)
        .accessibilityLabel("Show My Location")
        .accessibilityIdentifier("map-locate")
    }

    @ViewBuilder private var statusOverlay: some View {
        if model.isLoading && model.markers.isEmpty {
            ProgressView()
                .padding(20)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
        } else if let failure = model.failure, model.markers.isEmpty {
            ContentUnavailableView("Could not load the map", systemImage: "mappin.slash", description: Text(failure))
                .padding(24)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
                .padding(30)
        } else if !model.isLoading && model.markers.isEmpty {
            ContentUnavailableView(
                "No places yet",
                systemImage: "mappin.slash",
                description: Text("Photos with location data show up here.")
            )
            .padding(24)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .padding(30)
        }
    }

    // MARK: - interaction

    /// a lone marker opens its photo, a group zooms into itself, and a group
    /// that cannot be split any further hands its box to the timeline.
    private func select(_ cluster: MapCluster) {
        if cluster.count == 1 {
            open(cluster.representative)
            return
        }
        guard !cluster.isIndivisible, model.canZoomFurther else {
            area = MapAreaLink(
                title: cluster.placeName ?? "\(cluster.count) Photos",
                bounds: cluster.bounds
            )
            return
        }
        withAnimation(.easeInOut(duration: 0.35)) {
            camera = .rect(cluster.bounds.scaled(by: 1.6).mapRect)
        }
    }

    private func open(_ marker: MapMarker) {
        guard let client = session.client, openingAssetID == nil else { return }
        openingAssetID = marker.id
        Task {
            defer { openingAssetID = nil }
            guard let detail = try? await client.assetDetail(id: marker.id) else { return }
            viewer.present(assets: [detail.asAsset()], initialIndex: 0)
        }
    }

    private func frameMarkersIfNeeded() async {
        guard !didFrameMarkers else { return }
        if let initialCoordinate {
            didFrameMarkers = true
            camera = .region(MKCoordinateRegion(
                center: initialCoordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.4)
            ))
            return
        }
        // lands on the busiest part of the library instead of the outer extent,
        // which for a globe-spanning library is mostly ocean. clustered off
        // main - this used to freeze the screen right as it finished loading.
        let snapshot = model.markers
        guard !snapshot.isEmpty else { return }
        let bounds = await Task.detached(priority: .userInitiated) {
            let clusters = MapClustering.clusters(markers: snapshot, zoom: 4)
            return MapClustering.focusBounds(of: clusters) ?? MapClustering.bounds(of: snapshot)
        }.value
        guard let bounds, !didFrameMarkers else { return }
        didFrameMarkers = true
        // fitting a rect into a tall screen already pads one axis generously.
        camera = .rect(bounds.scaled(by: 1.08).mapRect)
    }
}

/// pushed grid of everything inside one box of the map.
nonisolated struct MapAreaLink: Hashable, Identifiable {
    let title: String
    let bounds: MapBoundingBox

    var id: String { "\(title)|\(bounds.query)" }
}

// MARK: - annotation

/// one map pin: a round thumbnail for a single asset, a counted circle for a
/// group - the same split the official web client makes.
private struct MapAssetMarker: View {
    let cluster: MapCluster
    let isOpening: Bool
    let thumbnailURL: URL?
    let action: () -> Void

    private var side: CGFloat {
        switch cluster.count {
        case 1: 46
        case 2..<25: 42
        case 25..<250: 50
        default: 58
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if cluster.count == 1 {
                    if let thumbnailURL {
                        RemoteImage(
                            url: thumbnailURL,
                            targetPixelSize: 160,
                            thumbhash: nil
                        )
                        .frame(width: side, height: side)
                        .clipShape(.circle)
                    } else {
                        Circle().fill(.quaternary).frame(width: side, height: side)
                    }
                } else {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: side, height: side)
                    Text(cluster.count.formatted())
                        .font(.system(size: cluster.count > 9_999 ? 12 : 15, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 4)
                }
            }
            .overlay {
                Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2)
            }
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            .opacity(isOpening ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("map-marker")
        .accessibilityLabel(cluster.count == 1 ? "Photo" : "\(cluster.count) photos")
        .accessibilityValue(cluster.placeName ?? "")
    }
}

// MARK: - settings

/// the map filters, matching the official map settings modal.
private struct MapSettingsSheet: View {
    @Binding var settings: MapSettings
    @Environment(\.dismiss) private var dismiss

    private static let ranges: [(label: String, days: Int)] = [
        ("All", 0),
        ("Past 24 Hours", 1),
        ("Past 7 Days", 7),
        ("Past 30 Days", 30),
        ("Past Year", 365),
        ("Past 3 Years", 1_095),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Only Favorites", isOn: $settings.onlyFavorites)
                    Toggle("Include Archived", isOn: $settings.includeArchived)
                    Toggle("Partner Photos", isOn: $settings.withPartners)
                    Toggle("Shared Albums", isOn: $settings.withSharedAlbums)
                }

                Section("Date Range") {
                    if settings.usesCustomRange {
                        DatePicker(
                            "After",
                            selection: Binding(
                                get: { settings.customFrom ?? Date().addingTimeInterval(-86_400 * 30) },
                                set: { settings.customFrom = $0 }
                            ),
                            in: ...(settings.customTo ?? .distantFuture),
                            displayedComponents: .date
                        )
                        DatePicker(
                            "Before",
                            selection: Binding(
                                get: { settings.customTo ?? Date() },
                                set: { settings.customTo = $0 }
                            ),
                            displayedComponents: .date
                        )
                        Button("Remove Custom Range") {
                            settings.customFrom = nil
                            settings.customTo = nil
                        }
                    } else {
                        Picker("Show", selection: $settings.relativeDays) {
                            ForEach(Self.ranges, id: \.days) { range in
                                Text(range.label).tag(range.days)
                            }
                        }
                        Button("Use Custom Range") {
                            settings.relativeDays = 0
                            settings.customFrom = Date().addingTimeInterval(-86_400 * 30)
                            settings.customTo = Date()
                        }
                    }
                }
            }
            .navigationTitle("Map Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("map-settings-done")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
