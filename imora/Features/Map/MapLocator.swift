import CoreLocation
import Foundation

/// a location fix. core location's own coordinate type is not equatable, so
/// swiftui cannot watch it for changes.
nonisolated struct MapFix: Equatable, Sendable {
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// one-shot "where am I" for the map button. the official clients ask for the
/// permission when the button is pressed rather than when the map opens, so
/// this only talks to core location on demand.
@Observable @MainActor
final class MapLocator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    /// last fix, cleared once the camera has consumed it.
    var fix: MapFix?
    var isLocating = false
    /// set when the permission is off for good, so the ui can offer settings.
    var isDenied = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func locate() {
        switch manager.authorizationStatus {
        case .notDetermined:
            isLocating = true
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            isDenied = true
        default:
            isLocating = true
            manager.requestLocation()
        }
    }

    private func handle(status: CLAuthorizationStatus) {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            guard isLocating else { return }
            manager.requestLocation()
        case .denied, .restricted:
            isLocating = false
            isDenied = true
        default:
            break
        }
    }

    // MARK: - delegate, called on the main queue by core location

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.handle(status: status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.last?.coordinate
        let fix = coordinate.map { MapFix(latitude: $0.latitude, longitude: $0.longitude) }
        Task { @MainActor in
            self.isLocating = false
            self.fix = fix
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.isLocating = false }
    }
}
