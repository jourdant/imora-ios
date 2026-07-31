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

    func markers(client: ImmichClient, options: MapMarkerOptions) async throws -> [MapMarker] {
        if let entry = entries[options], Date().timeIntervalSince(entry.fetchedAt) < lifetime {
            return entry.markers
        }
        if let task = inFlight[options] { return try await task.value }

        let task = Task { try await client.mapMarkers(options) }
        inFlight[options] = task
        defer { inFlight[options] = nil }
        let markers = try await task.value
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
    private var clusterTask: Task<Void, Never>?
    private var region: MKCoordinateRegion?
    private var viewportWidth: CGFloat = 0

    func load(client: ImmichClient, options: MapMarkerOptions) async {
        isLoading = true
        failure = nil
        do {
            markers = try await MapMarkerCache.shared.markers(client: client, options: options)
            clustersByZoom.removeAll()
            rebuildClusters(force: true)
        } catch {
            failure = error.localizedDescription
        }
        isLoading = false
    }

    /// called when the camera settles. recomputes the cluster set only when the
    /// zoom level actually changed - panning just re-filters.
    func cameraChanged(region: MKCoordinateRegion, viewportWidth: CGFloat) {
        self.region = region
        self.viewportWidth = viewportWidth
        let level = MapClustering.zoomLevel(
            longitudeDelta: region.span.longitudeDelta,
            widthPoints: viewportWidth
        )
        let changed = level != zoom
        zoom = level
        rebuildClusters(force: changed)
    }

    var canZoomFurther: Bool { zoom < MapClustering.maxZoom - 2 }

    /// box the browse button hands to the timeline.
    var visibleBounds: MapBoundingBox? {
        region.map { MapBoundingBox(region: $0) }
    }

    private func rebuildClusters(force: Bool) {
        guard !markers.isEmpty else {
            visibleClusters = []
            visibleCount = 0
            return
        }
        if let cached = clustersByZoom[zoom] {
            publish(cached)
            return
        }
        guard force || clusterTask == nil else { return }

        clusterTask?.cancel()
        let snapshot = markers
        let level = zoom
        clusterTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                MapClustering.clusters(markers: snapshot, zoom: level)
            }.value
            guard !Task.isCancelled, let self else { return }
            clustersByZoom[level] = built
            guard zoom == level else { return }
            publish(built)
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
