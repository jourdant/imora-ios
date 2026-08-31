import Foundation

/// what the map is allowed to show. mirrors the official map settings modal:
/// favourites, archive, partner and shared album assets, plus a date window
/// that is either one of the relative presets or a custom range.
nonisolated struct MapSettings: Codable, Hashable, Sendable {
    var onlyFavorites = false
    var includeArchived = false
    var withPartners = false
    var withSharedAlbums = false
    /// days back from now, 0 meaning all time. ignored while a custom range is set.
    var relativeDays = 0
    var customFrom: Date?
    var customTo: Date?

    var usesCustomRange: Bool { customFrom != nil || customTo != nil }

    var markerOptions: MapMarkerOptions {
        var options = MapMarkerOptions()
        options.isFavorite = onlyFavorites
        options.isArchived = includeArchived
        options.withPartners = withPartners
        options.withSharedAlbums = withSharedAlbums
        if usesCustomRange {
            options.createdAfter = customFrom
            options.createdBefore = customTo
        } else if relativeDays > 0 {
            // quantized to the hour so the value is stable across renders: a
            // cutoff that moves with the clock would miss the marker cache and
            // restart the load every time this is read.
            let cutoff = Date().addingTimeInterval(-Double(relativeDays) * 86_400).timeIntervalSince1970
            options.createdAfter = Date(timeIntervalSince1970: (cutoff / 3_600).rounded(.down) * 3_600)
        }
        return options
    }

    /// filter for the grid behind a map area. the buckets endpoint has no date
    /// window, same as the official web client's map panel.
    func timelineFilter(bbox: MapBoundingBox) -> TimelineFilter {
        var filter = TimelineFilter()
        filter.bbox = bbox.query
        filter.visibility = includeArchived ? nil : .timeline
        filter.withPartners = withPartners
        filter.isFavorite = onlyFavorites ? true : nil
        return filter
    }

    // MARK: - persistence

    private static let storageKey = "map-settings"

    static func load() -> MapSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(MapSettings.self, from: data) else {
            return MapSettings()
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
