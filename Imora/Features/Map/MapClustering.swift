import CoreLocation
import Foundation
import MapKit

// MARK: - bounding box

/// west/south/east/north corner box, the shape /timeline/buckets?bbox wants.
nonisolated struct MapBoundingBox: Hashable, Sendable {
    var west: Double
    var south: Double
    var east: Double
    var north: Double

    init(west: Double, south: Double, east: Double, north: Double) {
        self.west = west
        self.south = south
        self.east = east
        self.north = north
    }

    init(region: MKCoordinateRegion) {
        let halfLat = min(90, region.span.latitudeDelta / 2)
        let halfLon = min(180, region.span.longitudeDelta / 2)
        south = max(-90, region.center.latitude - halfLat)
        north = min(90, region.center.latitude + halfLat)
        west = max(-180, region.center.longitude - halfLon)
        east = min(180, region.center.longitude + halfLon)
    }

    /// query value the server expects. rounded outwards so an asset sitting
    /// exactly on an edge stays inside, and formatted fixed-width because a
    /// tiny span would otherwise print in exponential notation.
    var query: String {
        let values = [
            (west * 1e6).rounded(.down) / 1e6,
            (south * 1e6).rounded(.down) / 1e6,
            (east * 1e6).rounded(.up) / 1e6,
            (north * 1e6).rounded(.up) / 1e6,
        ]
        return values.map { String(format: "%.6f", $0) }.joined(separator: ",")
    }

    var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (south + north) / 2, longitude: (west + east) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max(north - south, 0.004),
                longitudeDelta: max(east - west, 0.004)
            )
        )
    }

    /// same box as a map rect. framing the camera on a rect letsMapKit fit it
    /// to the view's aspect ratio - a region of the raw span leaves the markers
    /// hugging one edge of a short, wide map.
    var mapRect: MKMapRect {
        let region = self.region
        let halfLat = region.span.latitudeDelta / 2
        let halfLon = region.span.longitudeDelta / 2
        // mercator has no poles, so the corners stay inside the projection.
        let top = CLLocationCoordinate2D(
            latitude: min(85, region.center.latitude + halfLat),
            longitude: max(-180, region.center.longitude - halfLon)
        )
        let bottom = CLLocationCoordinate2D(
            latitude: max(-85, region.center.latitude - halfLat),
            longitude: min(180, region.center.longitude + halfLon)
        )
        let a = MKMapPoint(top)
        let b = MKMapPoint(bottom)
        return MKMapRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    func contains(latitude: Double, longitude: Double) -> Bool {
        latitude >= south && latitude <= north && longitude >= west && longitude <= east
    }

    /// grows the box around its centre, e.g. to keep markers just off screen
    /// rendered or to leave breathing room when zooming to a cluster.
    func scaled(by factor: Double) -> MapBoundingBox {
        let latPad = (north - south) * (factor - 1) / 2
        let lonPad = (east - west) * (factor - 1) / 2
        return MapBoundingBox(
            west: max(-180, west - lonPad),
            south: max(-90, south - latPad),
            east: min(180, east + lonPad),
            north: min(90, north + latPad)
        )
    }
}

// MARK: - clusters

/// a group of markers close enough to share one annotation at the current
/// zoom. deliberately holds no member array - only what the annotation and
/// its tap need. carrying every member multiplied the whole marker set's
/// memory by every zoom level ever visited.
nonisolated struct MapCluster: Identifiable, Sendable {
    let id: String
    let latitude: Double
    let longitude: Double
    let count: Int
    /// the asset whose thumbnail stands for the whole group.
    let representative: MapMarker
    let placeName: String?
    let bounds: MapBoundingBox

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// every member sits on the same spot, so zooming cannot split the group.
    var isIndivisible: Bool {
        bounds.east - bounds.west < 1e-6 && bounds.north - bounds.south < 1e-6
    }
}

/// greedy radius clustering in web mercator space - the same model supercluster
/// gives the official web client, minus the kd-tree: seed on the first ungrouped
/// marker, absorb everything within one marker radius, repeat.
nonisolated enum MapClustering {
    /// screen points two markers must be apart to stay separate.
    static let radius: Double = 46
    static let maxZoom = 20

    /// zoom level whose 256 point tiles match the camera currently on screen.
    static func zoomLevel(longitudeDelta: Double, widthPoints: Double) -> Int {
        guard longitudeDelta > 0, widthPoints > 0 else { return 1 }
        let raw = log2(widthPoints * 360 / (256 * longitudeDelta))
        guard raw.isFinite else { return 1 }
        return min(maxZoom, max(0, Int(raw.rounded(.down))))
    }

    private struct Cell: Hashable {
        let x: Int
        let y: Int
    }

    static func clusters(markers: [MapMarker], zoom: Int) -> [MapCluster] {
        guard !markers.isEmpty else { return [] }
        let world = 256 * pow(2, Double(zoom))
        var xs = [Double](repeating: 0, count: markers.count)
        var ys = [Double](repeating: 0, count: markers.count)
        var grid: [Cell: [Int]] = [:]
        grid.reserveCapacity(markers.count)

        for (index, marker) in markers.enumerated() {
            let latitude = min(85.05112878, max(-85.05112878, marker.lat))
            let radians = latitude * .pi / 180
            xs[index] = (marker.lon + 180) / 360 * world
            ys[index] = (1 - log(tan(radians) + 1 / cos(radians)) / .pi) / 2 * world
            let cell = Cell(x: Int(floor(xs[index] / radius)), y: Int(floor(ys[index] / radius)))
            grid[cell, default: []].append(index)
        }

        var grouped = [Bool](repeating: false, count: markers.count)
        var result: [MapCluster] = []

        for seed in markers.indices where !grouped[seed] {
            grouped[seed] = true
            var members = [seed]
            let cellX = Int(floor(xs[seed] / radius))
            let cellY = Int(floor(ys[seed] / radius))
            // radius equals the cell size, so nothing further than one cell
            // away in either axis can be within reach.
            for dx in -1...1 {
                for dy in -1...1 {
                    guard let bucket = grid[Cell(x: cellX + dx, y: cellY + dy)] else { continue }
                    for candidate in bucket where !grouped[candidate] {
                        let distance = hypot(xs[candidate] - xs[seed], ys[candidate] - ys[seed])
                        guard distance <= radius else { continue }
                        grouped[candidate] = true
                        members.append(candidate)
                    }
                }
            }

            var west = markers[seed].lon
            var east = west
            var south = markers[seed].lat
            var north = south
            var latitudeSum = 0.0
            var longitudeSum = 0.0
            var placeName: String?
            for index in members {
                let marker = markers[index]
                if placeName == nil { placeName = marker.placeName }
                west = min(west, marker.lon)
                east = max(east, marker.lon)
                south = min(south, marker.lat)
                north = max(north, marker.lat)
                latitudeSum += marker.lat
                longitudeSum += marker.lon
            }

            result.append(MapCluster(
                id: markers[seed].id,
                latitude: latitudeSum / Double(members.count),
                longitude: longitudeSum / Double(members.count),
                count: members.count,
                representative: markers[seed],
                placeName: placeName,
                bounds: MapBoundingBox(west: west, south: south, east: east, north: north)
            ))
        }

        return result
    }

    /// box around the busiest groups, dropping the tail of far flung outliers.
    /// framing the outer extent of a library with one holiday photo on another
    /// continent zooms the camera out to an ocean.
    static func focusBounds(of clusters: [MapCluster], coverage: Double = 0.8) -> MapBoundingBox? {
        let total = clusters.reduce(0) { $0 + $1.count }
        guard total > 0 else { return nil }
        let target = Int(Double(total) * coverage)
        var covered = 0
        var box: MapBoundingBox?
        for cluster in clusters.sorted(by: { $0.count > $1.count }) {
            box = box.map {
                MapBoundingBox(
                    west: min($0.west, cluster.bounds.west),
                    south: min($0.south, cluster.bounds.south),
                    east: max($0.east, cluster.bounds.east),
                    north: max($0.north, cluster.bounds.north)
                )
            } ?? cluster.bounds
            covered += cluster.count
            if covered >= target { break }
        }
        return box
    }

    /// box that holds every marker, used to frame the map on first appearance.
    static func bounds(of markers: [MapMarker]) -> MapBoundingBox? {
        guard let first = markers.first else { return nil }
        var box = MapBoundingBox(west: first.lon, south: first.lat, east: first.lon, north: first.lat)
        for marker in markers.dropFirst() {
            box.west = min(box.west, marker.lon)
            box.east = max(box.east, marker.lon)
            box.south = min(box.south, marker.lat)
            box.north = max(box.north, marker.lat)
        }
        return box
    }
}
