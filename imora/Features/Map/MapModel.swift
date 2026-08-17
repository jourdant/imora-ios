import Foundation
import MapKit

/// the marker set is one unbounded fetch, so the places header and the map
/// screen share it instead of asking twice. entries expire because assets get
/// added, moved and deleted while the app stays open.
@MainActor
final class MapMarkerCache {
    static let shared = MapMarkerCache()

    private struct Entry {
        let markers: [MapMarker]
        let fetchedAt: Date
    }

    private var entries: [MapMarkerOptions: Entry] = [:]
    private var inFlight: [MapMarkerOptions: Task<[MapMarker], Error>] = [:]
    private let lifetime: TimeInterval = 300
    /// a full marker set can be tens of megabytes; combos beyond these are
    /// dead weight from a settings sheet exploration.
    private let entryLimit = 2

    func markers(client: ImmichClient, options: MapMarkerOptions) async throws -> [MapMarker] {
        if let entry = entries[options], Date().timeIntervalSince(entry.fetchedAt) < lifetime {
            return entry.markers
        }
        if let task = inFlight[options] { return try await task.value }

        let task = Task { try await client.mapMarkers(options) }
        inFlight[options] = task
        defer { inFlight[options] = nil }
        let markers = try await task.value
        // evict on write: expired entries and all but the freshest combos.
        entries = entries.filter { Date().timeIntervalSince($0.value.fetchedAt) < lifetime }
        while entries.count >= entryLimit,
              let oldest = entries.min(by: { $0.value.fetchedAt < $1.value.fetchedAt }) {
            entries[oldest.key] = nil
        }
        entries[options] = Entry(markers: markers, fetchedAt: Date())
        return markers
    }

    func invalidate() {
        entries.removeAll()
    }
}

/// holds every marker plus the clusters for the zoom currently on screen.
/// clustering runs off the main actor and is cached per zoom level, so panning
/// costs a bounds filter and zooming costs one pass over the markers.
@Observable @MainActor
final class MapModel {
    private(set) var visibleClusters: [MapCluster] = []
    private(set) var markers: [MapMarker] = []
    private(set) var isLoading = true
    private(set) var failure: String?
    /// markers inside the current viewport, what the browse button acts on.
    private(set) var visibleCount = 0
    private(set) var zoom = 0

    /// annotations past this point stop being readable and start costing frames.
    private let annotationLimit = 350

    private var clustersByZoom: [Int: [MapCluster]] = [:]
    private var region: MKCoordinateRegion?
    private var viewportWidth: CGFloat = 0
    /// zoom level currently being clustered off main, nil when idle. builds
    /// are serialized: a pinch through six levels used to run six full-set
    /// passes concurrently, five of them thrown away.
    private var buildingZoom: Int?
    /// bumped when the marker set is replaced, so a build snapshotted from
    /// the old set can never land in the fresh cache.
    private var markersVersion = 0
    /// bumped per load so a slow superseded fetch cannot overwrite the newer
    /// result - the cache task it awaits does not observe our cancellation.
    private var loadGeneration = 0

    func load(client: ImmichClient, options: MapMarkerOptions) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        failure = nil
        do {
            let fetched = try await MapMarkerCache.shared.markers(client: client, options: options)
            guard generation == loadGeneration else { return }
            markers = fetched
            markersVersion += 1
            clustersByZoom.removeAll()
            rebuildClusters()
        } catch {
            guard generation == loadGeneration else { return }
            failure = error.localizedDescription
        }
        isLoading = false
    }

    /// called when the camera settles. recomputes the cluster set only when the
    /// zoom level actually changed - panning just re-filters.
    func cameraChanged(region: MKCoordinateRegion, viewportWidth: CGFloat) {
        self.region = region
        self.viewportWidth = viewportWidth
        zoom = MapClustering.zoomLevel(
            longitudeDelta: region.span.longitudeDelta,
            widthPoints: viewportWidth
        )
        rebuildClusters()
    }

    var canZoomFurther: Bool { zoom < MapClustering.maxZoom - 2 }

    /// box the browse button hands to the timeline.
    var visibleBounds: MapBoundingBox? {
        region.map { MapBoundingBox(region: $0) }
    }

    private func rebuildClusters() {
        guard !markers.isEmpty else {
            visibleClusters = []
            visibleCount = 0
            return
        }
        if let cached = clustersByZoom[zoom] {
            publish(cached)
            return
        }
        guard buildingZoom == nil else { return }
        let snapshot = markers
        let level = zoom
        let version = markersVersion
        buildingZoom = level
        Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                MapClustering.clusters(markers: snapshot, zoom: level)
            }.value
            guard let self else { return }
            self.buildingZoom = nil
            // markers were replaced while this built; start over from them.
            guard self.markersVersion == version else {
                self.rebuildClusters()
                return
            }
            self.clustersByZoom[level] = built
            self.evictDistantZoomLevels(around: self.zoom)
            if self.zoom == level {
                self.publish(built)
            } else if self.clustersByZoom[self.zoom] == nil {
                // the camera moved on mid build; the finished work stays
                // cached and the level now on screen builds next.
                self.rebuildClusters()
            }
        }
    }

    /// levels far from the camera hold cluster sets sized like the library
    /// itself at street zooms; keeping every level ever visited added up.
    private func evictDistantZoomLevels(around level: Int) {
        for key in clustersByZoom.keys where abs(key - level) > 2 {
            clustersByZoom[key] = nil
        }
    }

    private func publish(_ clusters: [MapCluster]) {
        guard let region else {
            visibleClusters = Array(clusters.prefix(annotationLimit))
            visibleCount = clusters.reduce(0) { $0 + $1.count }
            return
        }
        let exact = MapBoundingBox(region: region)
        // a margin keeps markers just off screen mounted, so a short pan does
        // not pop them in.
        let padded = exact.scaled(by: 1.3)
        var inside: [MapCluster] = []
        var count = 0
        for cluster in clusters {
            if exact.contains(latitude: cluster.latitude, longitude: cluster.longitude) {
                count += cluster.count
            }
            if padded.contains(latitude: cluster.latitude, longitude: cluster.longitude) {
                inside.append(cluster)
            }
        }
        if inside.count > annotationLimit {
            inside.sort { $0.count > $1.count }
            inside = Array(inside.prefix(annotationLimit))
        }
        visibleCount = count
        visibleClusters = inside
    }
}
