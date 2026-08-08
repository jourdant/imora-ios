import Observation
import Photos

/// observable mirror of the photo library authorization, so the timeline
/// banner and the backup settings row re-render the moment a grant lands.
/// the app never asks at launch - the request only runs behind an explicit
/// user action.
@Observable
final class PhotoAccess {
    static let shared = PhotoAccess()

    private(set) var status: PHAuthorizationStatus

    private init() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// the system prompt was never shown, so asking is still possible.
    var canAsk: Bool { status == .notDetermined }

    /// the prompt cannot recover these - system settings is the only way up.
    var isBlocked: Bool {
        switch status {
        case .denied, .restricted, .limited: true
        default: false
        }
    }

    func refresh() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }
}
